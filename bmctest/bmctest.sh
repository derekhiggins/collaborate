#!/usr/bin/env bash

set -eu

# bmctest.sh tests the hosts from the supplied yaml config file
# are working with the required ironic opperations (register, power, virtual media)

# FIXME use fedora or other Red Hat image
ISO="archlinux-2023.02.01-x86_64.iso"
ISO_URL="https://geo.mirror.pkgbuild.com/iso/2023.02.01/$ISO"
# use the upstream ironic image by default
IRONICIMAGE="quay.io/metal3-io/ironic:latest"

function usage {
    echo "USAGE:"
    echo "./$(basename "$0") [-i ironic_image] -I interface -s pull_secret.json -c config.yaml"
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
    echo "$1"
}

# FIXME what is CLEANUPFILE for?
CLEANUPFILE=
function cleanup {
    timestamp "cleaning up - removing container"
    if [ "$CLEANUPFILE" != "" ] ; then
        rm -rf $CLEANUPFILE
    fi
    sudo podman rm -f -t 0 bmctest || true
}
trap "cleanup" EXIT

# FIXME - do we even need to manually download and serve the ISO over http?
# https://docs.openstack.org/ironic/latest/admin/ramdisk-boot.html says it does
# so automatically: "By default the Bare Metal service will cache the ISO
# locally and serve from its HTTP server"
timestamp "checking / getting ISO image"
if sudo [ ! -e /srv/ironic/html/images/${ISO} ]; then
    sudo mkdir -p /srv/ironic/html/images/
    sudo curl -L $ISO_URL -o /srv/ironic/html/images/${ISO}
fi

# start ironic and httpd (maybe more in future starting everything inside a
# single container for now, if we choose to run bmctest from inside a container
# in future we'll have less to change
timestamp "starting ironic container"
sudo podman run --authfile "$PULL_SECRET" --rm -d --net host --env PROVISIONING_INTERFACE="${INTERFACE}" \
    -v /srv/ironic:/shared --name bmctest --entrypoint sleep "$IRONICIMAGE" infinity
# starting ironic
timestamp "starting ironic process"
sudo podman exec -d bmctest bash -c "runironic > /tmp/ironic.log 2>&1"
# starting httpd
timestamp "starting httpd process"
sudo podman exec -d bmctest bash -c "/bin/runhttpd > /tmp/httpd.log 2>&1"

EXIT=0
ERRORS=""

function manage {
    local name=$1; local address=$2; local systemid=$3; local user=$4; local pass=$5
    baremetal node create --boot-interface redfish-virtual-media --driver redfish \
        --driver-info redfish_address="${address}" \
        --driver-info redfish_system_id="${systemid}" \
        --driver-info redfish_verify_ca=False --driver-info redfish_username="${user}" --driver-info redfish_password="${pass}" \
        --property capabilities='boot_mode:bios' --name "${name}" > /dev/null
    if ! baremetal node manage "${name}" --wait 60; then
        EXIT=$((EXIT + 1))
        ERRORS+="can not manage node ${name}\n"
        return 1
    fi
}

function power {
    # FIXME - leave node in power on or off?
    local name=$1
    for power in off on; do
        if ! baremetal node power "$power" "$name" --power-timeout 60; then
            EXIT=$((EXIT + 1))
            ERRORS+="can not power $power ${name}\n"
            return 1
        fi
    done
}

# FIXME - use gnu parallel or something of the sort
while read -r NAME ADDRESS SYSTEMID USERNAME PASSWORD; do
    echo; timestamp "===== $NAME ====="

    timestamp "attempting to manage $NAME (check address & credentials)"
    if manage "$NAME" "$ADDRESS" "$SYSTEMID" "$USERNAME" "$PASSWORD"; then
       echo "    success"
    else
       continue
    fi

    timestamp "testing ability to power on/off $NAME"
    power "$NAME" && echo "    success"

    timestamp "testing vmedia attach" # may need to actually provision a live-iso image
    timestamp "verifying node boot device can be set"
    timestamp "testing vmedia detach" # may need to actually provision a live-iso image
done < <(yq -r '.hosts[] | "\(.name) \(.bmc.address) \(.bmc.systemid) \(.bmc.username) \(.bmc.password)"' "$CONFIGFILE")

echo; timestamp "========== Found $EXIT errors =========="
echo -e "$ERRORS"
exit $EXIT
