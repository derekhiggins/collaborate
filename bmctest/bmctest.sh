#!/usr/bin/env bash

set -eu

# bmctest.sh tests the hosts from the supplied yaml config file
# are working with the required ironic opperations (register, power, virtual media)

ISO="archlinux-2023.02.01-x86_64.iso"
ISO_URL="https://geo.mirror.pkgbuild.com/iso/2023.02.01/$ISO"
# use the upstream ironic image by default
IRONICIMAGE="quay.io/metal3-io/ironic:latest"

function usage {
    echo "USAGE:"
    echo "./$(basename $0) [-i ironic_image] -I interface -s pull_secret.json -c config.yaml"
    echo "ironic image defaults to $IRONICIMAGE"
}

while getopts "i:I:s:c:h" opt; do
    case $opt in
        h) usage; exit 0 ;;
        i) IRONICIMAGE=$OPTARG ;;
        I) INTERFACE=$OPTARG ;;
        s) PULL_SECRET=$OPTARG ;;
        c) CONFIGFILE=$OPTARG ;;
        ?) usage; exit 1 ;;
    esac
done

if [[ -z ${INTERFACE:-} ]]; then
    echo "you must provide the network interface"
    usage
    exit 1
fi

if [[ ! -e ${CONFIGFILE:-} || ! -e ${PULL_SECRET:-} ]]; then
    echo "invalid config file or pull secret file"
    usage
    exit 1
fi

function timestamp {
    echo -n "$(date +%T) "
}

CLEANUPFILE=
function cleanup {
    timestamp; echo "cleaning up"
    if [ "$CLEANUPFILE" != "" ] ; then
        rm -rf $CLEANUPFILE
    fi
    sudo podman rm -f -t 0 bmctest || true
}
trap "cleanup" EXIT

timestamp; echo "checking / getting ISO image"
if sudo [ ! -e /srv/ironic/html/images/${ISO} ]; then
    sudo mkdir -p /srv/ironic/html/images/
    sudo curl -L $ISO_URL -o /srv/ironic/html/images/${ISO}
    sudo md5sum /srv/ironic/html/images${ISO} | awk '{print $1}' | sudo dd of=/srv/ironic/html/images/${ISO}.md5sum
fi

# start ironic and httpd (maybe more in future starting everything inside a
# single container for now, if we choose to run bmctest from inside a container
# in future we'll have less to change
timestamp; echo "starting ironic container"
sudo podman run --authfile $PULL_SECRET --rm -d --net host --env PROVISIONING_INTERFACE=${INTERFACE} \
    -v /srv/ironic:/shared --name bmctest --entrypoint sleep $IRONICIMAGE infinity
# starting ironic
timestamp; echo "starting ironic process"
sudo podman exec -d bmctest bash -c "runironic > /tmp/ironic.log 2>&1"
# starting httpd
timestamp; echo "starting httpd process"
sudo podman exec -d bmctest bash -c "/bin/runhttpd > /tmp/httpd.log 2>&1"

### for each node in install-config.yaml
for NODE in $(cat $CONFIGFILE | yq .hosts[].name -r) ; do
    timestamp; echo "== $NODE =="
    timestamp; echo "Verifitying node credentials" # Can be done by just registering node with ironic
    timestamp; echo "testing ability to power on/off node" # baremetal node power on X
    timestamp; echo "testing vmedia attach" # may need to actually provision a live-iso image
    timestamp; echo "verifying node boot device can be set"
    timestamp; echo "testing vmedia detach" # may need to actually provision a live-iso image
done
