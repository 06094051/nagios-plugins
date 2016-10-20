#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2015-10-07 13:41:58 +0100 (Wed, 07 Oct 2015)
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

#[ `uname -s` = "Linux" ] || exit 0

# No longer used, done as part of Linux checks now
return 0 &>/dev/null || :
exit 0

echo "
# ============================================================================ #
#                                     Y u m
# ============================================================================ #
"

export DOCKER_IMAGE="harisekhon/centos-github"
export DOCKER_CONTAINER="nagios-plugins-centos-test"

export MNTDIR="/tmp/nagios-plugins"

if ! is_docker_available; then
    echo 'WARNING: Docker not found, skipping CentOS Yum checks!!!'
    exit 0
fi

docker_exec(){
    local cmd="$@"
    docker exec "$DOCKER_CONTAINER" $MNTDIR/$*
}

startupwait=0

echo "Setting up CentOS test container"
DOCKER_OPTS="-v $srcdir/..:$MNTDIR"
DOCKER_CMD="tail -f /dev/null"
launch_container "$DOCKER_IMAGE" "$DOCKER_CONTAINER"
docker exec "$DOCKER_CONTAINER" yum makecache fast
#docker exec "$DOCKER_CONTAINER" yum install -y net-tools
if [ -n "${NOTESTS:-}" ]; then
    exit 0
fi
hr
docker_exec check_yum.pl -C -v -t 30
hr
docker_exec check_yum.pl -C --all-updates -v -t 30 || :
hr
docker_exec check_yum.py -C -v -t 30
hr
docker_exec check_yum.py -C --all-updates -v -t 30 || :
hr
delete_container
echo; echo
