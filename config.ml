open Mirage

let packages =
  [ package "uri";
    package "magic-mime";
    package "cohttp-mirage";
    package "letsencrypt";
    package ~min:"0.8.7" "fmt"
  ]

let stack = generic_stackv4v6 default_network

let data =
  let data_key = Key.(value @@ kv_ro ~group:"data" ()) in
  generic_kv_ro ~key:data_key "htdocs"

let http_port =
  let doc = Key.Arg.info ~doc:"Listening HTTP port." [ "http" ] in
  Key.(create "http_port" Arg.(opt int 80 doc))

let https_port =
  let doc = Key.Arg.info ~doc:"Listening HTTPS port." [ "https" ] in
  Key.(create "https_port" Arg.(opt int 443 doc))

let hostname =
  let doc = Key.Arg.info ~doc:"Server hostname." [ "hostname" ] in
  Key.(create "hostname" Arg.(required string doc))

let le_production =
  let doc = Key.Arg.info ~doc:"Query Let's Encrypt production servers" [ "le_production" ] in
  Key.(create "le_production" Arg.(opt bool false doc))

let main =
  let keys =
    [ Key.abstract http_port;
      Key.abstract https_port;
      Key.abstract hostname;
      Key.abstract le_production
    ]
  in
  foreign
    ~packages
    ~keys
    "Dispatch.HTTPS"
    (pclock @-> resolver @-> conduit @-> kv_ro @-> time @-> http_client @-> http @-> job)

let () =
  let res_dns = resolver_dns stack in
  let conduit = conduit_direct ~tls:true stack in
  let cohttp_server = cohttp_server conduit in
  let cohttp_client = cohttp_client res_dns conduit in
  register
    "mvgce"
    [ main
      $ default_posix_clock
      $ res_dns
      $ conduit
      $ data
      $ default_time
      $ cohttp_client
      $ cohttp_server
    ]
