#!/bin/bash

set -e

mirage clean || /bin/true
#mirage configure -t virtio --dhcp true
mirage configure -t virtio --net direct --dhcp false --ipv4 10.0.0.27/32 --resolver 4.2.2.2
make depends
make
