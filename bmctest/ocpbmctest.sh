#!/usr/bin/env bash

set -eu

# intermediate script to parse install-config.yaml,
# create the ironic image from openshift release and then call bmctest.sh

# defaults
RELEASE='4.13'
PULL_SECRET='/opt/dev-scripts/pull_secret.json '

function usage {
    echo "USAGE:"
    echo "./$(basename $0) [-r release_version] -c install-config.yaml"
    echo "release version defaults to $RELEASE"
}

while getopts "r:c:h" opt; do
    case $opt in
        h) usage; exit 0 ;;
        r) RELEASE=$OPTARG ;;
        c) CONFIGFILE=$OPTARG ;;
        ?) usage; exit 1 ;;
    esac
done

if [[ ! -f ${CONFIGFILE:-} ]]; then
    echo "invalid config file"
    usage
    exit 1
fi

function timestamp {
    echo -n "$(date +%T) "
}

timestamp; echo "getting the release image url"
RELEASEIMAGE=$(curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp-dev-preview/latest-${RELEASE}/release.txt \
    | grep -o 'quay.io/openshift-release-dev/ocp-release.*')


# upstream version will use a metal3 ironic image
timestamp; echo "creating the ironic image"
IRONICIMAGE=$(podman run --rm $RELEASEIMAGE image ironic)

INPUTFILE=$(mktemp)
function cleanup {
    rm -rf $INPUTFILE
}
trap "cleanup" EXIT


# Format of this might change before going upstream but for the moment lets use the hosts part of install-config.yaml
# TODO: may need other values from install-config.yaml e.g. externalBridge...
echo "hosts:" > $INPUTFILE
timestamp; echo "extracting the hosts from install-config yaml"
cat $CONFIGFILE | yq -y .platform.baremetal.hosts >> $INPUTFILE

timestamp; echo "calling bmctest.sh"
$(dirname $0)/bmctest.sh -i $IRONICIMAGE -s $PULL_SECRET -c $INPUTFILE
