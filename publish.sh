#!/bin/bash

export MY_PROJECT=mirage-199999921
export MY_REGION=us-west1
export MY_ZONE=$MY_REGION-a
export IDENTIFIER=$(date '+%Y%m%d%H%M%S')

set -e

./build.sh
solo5-virtio-mkimage -f tar -- mvgce.tar.gz ./mvgce.virtio -- --ipv4-only=true --hostname mvgce.bacarella.com

gsutil cp mvgce.tar.gz gs://$MY_PROJECT/mvgce.tar.gz

# Since it takes awhile, in a separate thread, stop the instance and detach the disk
(
  gcloud compute instances stop mvgce --zone $MY_ZONE
  boot_disk=$(gcloud compute instances describe mvgce --zone $MY_ZONE | grep disks/mvgce- | awk -F'/' '{print $11}')
  gcloud compute instances detach-disk mvgce --disk $boot_disk --zone $MY_ZONE
) &

child_pid=$!

# This next step also takes awhile.
gcloud compute images create mvgce-$IDENTIFIER --source-uri gs://$MY_PROJECT/mvgce.tar.gz
gcloud compute disks create mvgce-$IDENTIFIER --image mvgce-$IDENTIFIER --zone=$MY_ZONE

# Make sure the instance is shut down and its boot disk is detached before we try to update it.
wait $child_pid

gcloud compute instances attach-disk mvgce --boot --disk mvgce-$IDENTIFIER --zone $MY_ZONE
gcloud compute instances start mvgce --zone $MY_ZONE
