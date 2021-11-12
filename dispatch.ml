open Lwt.Infix

(** Common signature for http and https. *)
module type HTTP = Cohttp_mirage.Server.S

(* Logging *)
let https_src = Logs.Src.create "https" ~doc:"HTTPS server"

module Https_log = (val Logs.src_log https_src : Logs.LOG)

let http_src = Logs.Src.create "http" ~doc:"HTTP server"

module Http_log = (val Logs.src_log http_src : Logs.LOG)

module Dispatch (FS : Mirage_kv.RO) (S : HTTP) = struct
  let failf fmt = Fmt.kstr Lwt.fail_with fmt

  (* given a URI, find the appropriate file, and construct a response with its contents. *)
  let rec dispatcher fs uri =
    match Uri.path uri with
    | "" | "/" -> dispatcher fs (Uri.with_path uri "index.html")
    | path ->
      let header = Cohttp.Header.init_with "Strict-Transport-Security" "max-age=31536000" in
      let mimetype = Magic_mime.lookup path in
      let headers = Cohttp.Header.add header "content-type" mimetype in
      Lwt.catch
        (fun () ->
          FS.get fs (Mirage_kv.Key.v path)
          >>= function
          | Error e -> failf "get: %a" FS.pp_error e
          | Ok body -> S.respond_string ~status:`OK ~body ~headers ())
        (fun _exn -> S.respond_not_found ())

  (* Answer letsencrypt verification queries and redirect everything else to HTTPS. *)
  let letsencrypt_or_redirect ~letsencrypt_tokens ~port uri =
    Http_log.info (fun f -> f "request: %s" (Uri.to_string uri));
    let path = Uri.path uri in
    match
      String.split_on_char '/' path
      |> List.filter (function
             | "" -> false
             | _ -> true)
    with
    | [ ".well-known"; "acme-challenge"; token ] ->
      Http_log.info (fun f -> f "Let's Encrypt challenge lookup: %s" path);
      (match Hashtbl.find_opt letsencrypt_tokens token with
      | None -> S.respond ~status:`Not_found ~body:`Empty ()
      | Some data ->
        let headers =
          Cohttp.Header.of_list
            [ "content-type", "application/octet-stream";
              "content-length", string_of_int (String.length data)
            ]
        in
        S.respond_string ~headers ~status:`OK ~body:data ())
    | _ ->
      let new_uri = Uri.with_scheme uri (Some "https") in
      let new_uri = Uri.with_port new_uri (Some port) in
      Http_log.info (fun f -> f "[%s] -> [%s]" (Uri.to_string uri) (Uri.to_string new_uri));
      let headers = Cohttp.Header.init_with "location" (Uri.to_string new_uri) in
      S.respond ~headers ~status:`Moved_permanently ~body:`Empty ()

  let serve dispatch =
    let callback (_, cid) request _body =
      let uri = Cohttp.Request.uri request in
      let cid = Cohttp.Connection.to_string cid in
      Https_log.info (fun f -> f "[%s] serving %s." cid (Uri.to_string uri));
      dispatch uri
    in
    let conn_closed (_, cid) =
      let cid = Cohttp.Connection.to_string cid in
      Https_log.info (fun f -> f "[%s] closing" cid)
    in
    S.make ~conn_closed ~callback ()
end

module HTTPS
    (Pclock : Mirage_clock.PCLOCK)
    (Resolv : Resolver_mirage.S)
    (Conduit : Conduit_mirage.S)
    (Data : Mirage_kv.RO)
    (Time : Mirage_time.S)
    (Http_client : Cohttp_lwt.S.Client)
    (Http_server : HTTP) =
struct
  module D = Dispatch (Data) (Http_server)

  let certificate_seed = None
  let certificate_key_bits = None
  let account_seed = None
  let account_key_bits = None
  let certificate_key_type = `RSA
  let account_key_type = `RSA
  let email_address = None

  module Letsencrypt_cert = struct
    module Acme_cohttp = Letsencrypt.Client.Make (struct
      module Headers = Cohttp.Header
      module Body = Cohttp_lwt.Body

      module Response = struct
        include Cohttp.Response

        let status resp = Cohttp.Code.code_of_status (Cohttp.Response.status resp)
      end

      include Cohttp_mirage.Client.Make (Pclock) (Resolv) (Conduit)
    end)

    let gen_key ?seed ?bits key_type =
      let seed = Option.map Cstruct.of_string seed in
      X509.Private_key.generate ?seed ?bits key_type

    let csr key host =
      let host = Domain_name.to_string host in
      let cn = X509.[ Distinguished_name.(Relative_distinguished_name.singleton (CN host)) ] in
      X509.Signing_request.create cn key

    let solver _host ~tokens ~prefix:_ ~token ~content =
      Hashtbl.replace tokens token content;
      Lwt.return (Ok ())

    let provision_certificate ~ctx ~production ~letsencrypt_tokens =
      let ( >>? ) = Lwt_result.bind in
      let endpoint =
        if production
        then Letsencrypt.letsencrypt_production_url
        else Letsencrypt.letsencrypt_staging_url
      in
      Https_log.info (fun f ->
          f "ACME endpoint: %s (production: %B)" (Uri.to_string endpoint) production);
      let priv = gen_key ?seed:certificate_seed ?bits:certificate_key_bits certificate_key_type in
      let my_hostname =
        let hostname_s = Key_gen.hostname () in
        Https_log.info (fun f -> f "my hostname: %s" hostname_s);
        match Domain_name.of_string hostname_s with
        | Ok domain -> domain
        | Error (`Msg s) -> failwith (Printf.sprintf "Invalid hostname '%s': %s" hostname_s s)
      in
      Https_log.info (fun f -> f "create CSR");
      match csr priv my_hostname with
      | Error _ as err -> Lwt.return err
      | Ok csr ->
        let account_key = gen_key ?seed:account_seed ?bits:account_key_bits account_key_type in
        Https_log.info (fun f -> f "Acme_cohttp.initialize");
        Acme_cohttp.initialise ?email:email_address ~ctx ~endpoint account_key
        >>? fun le ->
        let sleep sec = Time.sleep_ns (Duration.of_sec sec) in
        let solver =
          let solver host ~prefix ~token ~content =
            solver host ~prefix ~tokens:letsencrypt_tokens ~token ~content
          in
          Letsencrypt.Client.http_solver solver
        in
        Https_log.info (fun f -> f "Acme_cohttp.sign");
        Acme_cohttp.sign_certificate solver le sleep csr
        >>? fun certs -> Lwt.return_ok (`Single (certs, priv))

    let tls_config ?(production = true) ~ctx ~letsencrypt_tokens () =
      provision_certificate ~ctx ~production ~letsencrypt_tokens
      >>= fun res ->
      match res with
      | Error (`Msg s) -> failwith (Printf.sprintf "Failed to provision certificate: %s" s)
      | Ok certificates -> Lwt.return (Tls.Config.server ~certificates ())
  end

  let start _clock _resolver _conduit_tls data _time cohttp_client start_http =
    let letsencrypt_tokens = Hashtbl.create 1 in
    let http =
      let http_port = Key_gen.http_port () in
      let tcp = `TCP http_port in
      Http_log.info (fun f -> f "listening on %d/TCP" http_port);
      start_http tcp @@ D.serve (D.letsencrypt_or_redirect ~letsencrypt_tokens ~port:http_port)
    in
    Https_log.info (fun f -> f "provisioning TLS certificate with ACME/Let's Encrypt");
    Letsencrypt_cert.tls_config
      ~ctx:cohttp_client
      ~production:(Key_gen.le_production ())
      ~letsencrypt_tokens
      ()
    >>= fun tls_cfg ->
    let https =
      let https_port = Key_gen.https_port () in
      let tls = `TLS (tls_cfg, `TCP https_port) in
      Https_log.info (fun f -> f "listening on %d/TCP" https_port);
      start_http tls @@ D.serve (D.dispatcher data)
    in
    Lwt.join [ https; http ]
end
