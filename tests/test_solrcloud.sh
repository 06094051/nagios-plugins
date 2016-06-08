#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2016-01-22 21:13:49 +0000 (Fri, 22 Jan 2016)
#
#  https://github.com/harisekhon/nagios-plugins
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback
#
#  https://www.linkedin.com/in/harisekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir2="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "$srcdir2/.."

. ./tests/utils.sh

srcdir="$srcdir2"

echo "
# ============================================================================ #
#                               S o l r C l o u d
# ============================================================================ #
"

export SOLR_VERSIONS="${@:-latest 4.10 5.5 6.0}"

SOLR_HOST="${DOCKER_HOST:-${SOLR_HOST:-${HOST:-localhost}}}"
SOLR_HOST="${SOLR_HOST##*/}"
export SOLR_HOST="${SOLR_HOST%%:*}"
export ZOOKEEPER_HOST="$SOLR_HOST"

export DOCKER_IMAGE="harisekhon/solrcloud-dev"
export DOCKER_CONTAINER="nagios-plugins-solrcloud-test"

export SOLR_HOME="/solr"
export MNTDIR="/pl"

startupwait=60

if ! is_docker_available; then
    echo 'WARNING: Docker not found, skipping Hadoop checks!!!'
    exit 0
fi

docker_exec(){
    docker exec -ti "$DOCKER_CONTAINER" $MNTDIR/$@
}

test_solrcloud(){
    local version="$1"
    travis_sample || continue
    # SolrCloud 4.x needs some different args / locations
    if [ ${version:0:1} = 4 ]; then
        four=true
        export SOLR_COLLECTION="collection1"
    else
        four=""
        export SOLR_COLLECTION="gettingstarted"
    fi
    echo "Setting up SolrCloud $version docker test container"
    DOCKER_OPTS="-v $srcdir/..:$MNTDIR"
    launch_container "$DOCKER_IMAGE:$version" "$DOCKER_CONTAINER" 8983 8984 9983

    hr
    ./check_solr_version.py -e "$version"
    hr
    # docker is running slow
    $perl -T $I_lib ./check_solrcloud_cluster_status.pl -v -t 60
    hr
    # FIXME: solr 5/6
    docker_exec check_solrcloud_cluster_status_zookeeper.pl -H localhost -P 9983 -b / -v
    hr
    # FIXME: doesn't pick up collection from env
    if [ -n "$four" ]; then
        docker_exec check_solrcloud_config_zookeeper.pl -H localhost -P 9983 -b / -C "$SOLR_COLLECTION" -d "/solr/node1/solr/$SOLR_COLLECTION/conf" -v
    else
        # TODO: review why there is no solrcloud example config - this was the closest one I found via:
        # find /solr/ -name solrconfig.xml | while read filename; dirname=$(dirname $filename); do echo $dirname; /pl/check_solrcloud_config_zookeeper.pl -H localhost -P 9983 -b / -C gettingstarted -d $dirname -v; echo; done
        set +o pipefail
        docker_exec check_solrcloud_config_zookeeper.pl -H localhost -P 9983 -b / -C "$SOLR_COLLECTION" -d "$SOLR_HOME/server/solr/configsets/data_driven_schema_configs/conf" -v | grep -F '1 file only found in ZooKeeper but not local directory (configoverlay.json)'
        set -o pipefail
    fi
    hr
    # FIXME: why is only 1 node up instead of 2
    $perl -T $I_lib ./check_solrcloud_live_nodes.pl -w 1 -c 1 -t 60 -v
    hr
    docker_exec check_solrcloud_live_nodes_zookeeper.pl -H localhost -P 9983 -b / -w 1 -c 1 -v
    hr
    # docker is running slow
    $perl -T $I_lib ./check_solrcloud_overseer.pl -t 60 -v
    hr
    docker_exec check_solrcloud_overseer_zookeeper.pl -H localhost -P 9983 -b / -v
    hr
    docker_exec check_solrcloud_server_znode.pl -H localhost -P 9983 -z /live_nodes/$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$DOCKER_CONTAINER"):8983_solr -v
    hr
    # FIXME: second node does not come/stay up
    # docker_exec check_solrcloud_server_znode.pl -H localhost -P 9983 -z /live_nodes/$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$DOCKER_CONTAINER"):8984_solr -v
    hr
    if [ -n "$four" ]; then
        docker_exec check_zookeeper_config.pl -H localhost -P 9983 -C "$SOLR_HOME/node1/solr/zoo.cfg" --no-warn-extra -v
    else
        docker_exec check_zookeeper_config.pl -H localhost -P 9983 -C "$SOLR_HOME/example/cloud/node1/solr/zoo.cfg" --no-warn-extra -v
    fi
    hr
    delete_container
    hr
    echo
}

for version in $SOLR_VERSIONS; do
    test_solrcloud $version
done
