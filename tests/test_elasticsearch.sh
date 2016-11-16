#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2015-05-25 01:38:24 +0100 (Mon, 25 May 2015)
#
#  https://github.com/harisekhon/nagios-plugins
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback to help improve or steer this or other code I publish
#
#  https://www.linkedin.com/in/harisekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd "$srcdir/..";

. ./tests/utils.sh

echo "
# ============================================================================ #
#                           E l a s t i c s e a r c h
# ============================================================================ #
"

export ELASTICSEARCH_VERSIONS="${@:-${ELASTICSEARCH_VERSIONS:-latest 1.4 1.5 1.6 1.7 2.0 2.2 2.3 2.4 5.0}}"

ELASTICSEARCH_HOST="${DOCKER_HOST:-${ELASTICSEARCH_HOST:-${HOST:-localhost}}}"
ELASTICSEARCH_HOST="${ELASTICSEARCH_HOST##*/}"
ELASTICSEARCH_HOST="${ELASTICSEARCH_HOST%%:*}"
export ELASTICSEARCH_HOST
export ELASTICSEARCH_PORT="${ELASTICSEARCH_PORT:-9200}"
export ELASTICSEARCH_INDEX="${ELASTICSEARCH_INDEX:-test}"

export DOCKER_IMAGE="elasticsearch"
export DOCKER_CONTAINER="nagios-plugins-elasticsearch-test"

startupwait 20

if ! is_docker_available; then
    echo 'WARNING: Docker not found, skipping Elasticsearch checks!!!'
    exit 0
fi

test_elasticsearch(){
    local version="$1"
    echo "Setting up Elasticsearch $version test container"
    launch_container "$DOCKER_IMAGE:$version" "$DOCKER_CONTAINER" $ELASTICSEARCH_PORT
    if [ -n "${NOTESTS:-}" ]; then
        return 0
    fi
    when_ports_available $startupwait $ELASTICSEARCH_HOST $ELASTICSEARCH_PORT
    # Travis added this
    #echo "deleting twitter index as 5 unassigned shards are breaking tests"
    #curl -XDELETE "http://localhost:9200/twitter" || :
    #curl -XDELETE "http://$ELASTICSEARCH_HOST:$ELASTICSEARCH_PORT/$ELASTICSEARCH_INDEX" || :
    # always returns 0 and I don't wanna parse the json error
    #if ! curl -s "http://$ELASTICSEARCH_HOST:$ELASTICSEARCH_PORT/$ELASTICSEARCH_INDEX" &>/dev/null; then

    if ! $perl -T ./check_elasticsearch_index_exists.pl --list-indices | grep "^[[:space:]]*$ELASTICSEARCH_INDEX[[:space:]]*$"; then
        echo "creating test Elasticsearch index '$ELASTICSEARCH_INDEX'"
        curl -iv -XPUT "http://$ELASTICSEARCH_HOST:$ELASTICSEARCH_PORT/$ELASTICSEARCH_INDEX/" -d '
        {
            "settings": {
                "index": {
                    "number_of_shards": 1,
                    "number_of_replicas": 0
                }
            }
        }
        '
    fi
    echo
    echo "Setup done, starting checks ..."
    hr
    if [ "$version" = "latest" ]; then
        local version=".*"
    fi
    echo
    $perl -T ./check_elasticsearch.pl -v --es-version "$version"
    hr
    # Listing checks return UNKNOWN
    set +e
    # _cat/fielddata API is no longer outputs lines for 0b fielddata nodes in Elasticsearch 5.0 - https://github.com/elastic/elasticsearch/issues/21564
    #export ELASTICSEARCH_NODE="$(DEBUG='' $perl -T ./check_elasticsearch_fielddata.pl --list-nodes | grep -v -e '^Nodes' -e '^Hostname' -e '^[[:space:]]*$' | awk '{print $1; exit}' )"
    # this works too but let's test the --list-nodes from one of the plugins
    #export ELASTICSEARCH_NODE="$(curl -s $HOST:9200/_nodes | python -c 'import json, sys; print json.load(sys.stdin)["nodes"].values()[0]["node"]')"
    # taking hostname not node name here, ip is $2, node name is $3
    export ELASTICSEARCH_NODE="$(DEBUG='' $perl -T ./check_elasticsearch_node_disk_percent.pl --list-nodes | grep -vi -e '^Elasticsearch Nodes' -e '^Hostname' -e '^[[:space:]]*$' | awk '{print $1; exit}' )"
    [ -n "$ELASTICSEARCH_NODE" ] || die "failed to determine Elasticsearch node name from API!"
    echo "determined Elasticsearch node => $ELASTICSEARCH_NODE"
    #result=$?
    #[ $result = 3 ] || exit $result
    hr
    $perl -T ./check_elasticsearch_index_exists.pl --list-indices
    result=$?
    [ $result = 3 ] || exit $result
    set -e
    hr
    $perl -T ./check_elasticsearch_cluster_disk_balance.pl -v
    hr
    $perl -T ./check_elasticsearch_cluster_shards.pl -v # --unassigned-shards 5,5 # travis now has 5 unassigned shards for some reason
    hr
    $perl -T ./check_elasticsearch_cluster_shard_balance.pl -v
    hr
    $perl -T ./check_elasticsearch_cluster_stats.pl -v
    hr
    set +e
    $perl -T ./check_elasticsearch_cluster_status.pl -v
    # travis has yellow status
    result=$?
    [ $result = 0 -o $result = 1 ] || exit $result
    set -e
    hr
    $perl -T ./check_elasticsearch_cluster_status_nodes_shards.pl -v
    hr
    $perl -T ./check_elasticsearch_data_nodes.pl -w 1 -v
    hr
    $perl -T ./check_elasticsearch_doc_count.pl -v
    hr
    # _cat/fielddata API is no longer outputs lines for 0b fielddata nodes in Elasticsearch 5.0 - https://github.com/elastic/elasticsearch/issues/21564
    $perl -T ./check_elasticsearch_fielddata.pl -N "$ELASTICSEARCH_NODE" -v
    hr
    $perl -T ./check_elasticsearch_index_exists.pl -v
    hr
    $perl -T ./check_elasticsearch_index_age.pl -v -w 0:1
    #hr
    #perl -T ./check_elasticsearch_index_health.pl -v
    hr
    $perl -T ./check_elasticsearch_index_replicas.pl -w 0 -v
    hr
    $perl -T ./check_elasticsearch_index_settings.pl -v
    hr
    $perl -T ./check_elasticsearch_index_shards.pl -v
    hr
    $perl -T ./check_elasticsearch_index_stats.pl -v
    hr
    $perl -T ./check_elasticsearch_master_node.pl -v
    hr
    $perl -T ./check_elasticsearch_nodes.pl -v -w 1
    hr
    $perl -T ./check_elasticsearch_node_disk_percent.pl -N "$ELASTICSEARCH_NODE" -v -w 90 -c 95
    hr
    $perl -T ./check_elasticsearch_node_shards.pl -N "$ELASTICSEARCH_NODE" -v
    hr
    $perl -T ./check_elasticsearch_node_stats.pl -N "$ELASTICSEARCH_NODE" -v
    hr
    $perl -T ./check_elasticsearch_pending_tasks.pl -v
    hr
    $perl -T ./check_elasticsearch_shards_state_detail.pl -v
    hr
    delete_container
}

for version in $(ci_sample $ELASTICSEARCH_VERSIONS); do
    test_elasticsearch $version
done
