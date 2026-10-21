#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
#	zpool export unmounts a tree of datasets in parallel, children before
#	parents, and fails cleanly if a dataset is busy.
#
# STRATEGY:
#	1. Create a pool with a 3-level tree of datasets, plus a dataset whose
#	   mountpoint is nested in another branch of the tree, and a mounted
#	   snapshot. Write a file to every dataset.
#	2. Export and import the pool with the default parallelism, then with
#	   ZFS_UNMOUNT_PARALLELISM=1 and =4. Verify each export leaves nothing
#	   mounted and each import mounts every dataset with its data intact.
#	3. Hold a file open in a deep dataset. Verify export fails, names the
#	   busy mountpoint, and leaves the pool imported with the busy dataset
#	   and its parent mounted.
#	4. Close the file and verify export succeeds.
#

verify_runnable "global"

POOL=pu_pool
VDEV=$TEST_BASE_DIR/pu_vdev
MNT=$TEST_BASE_DIR/pu_mnt
TOP=3
MID=3
LEAF=4

function cleanup
{
	exec 3<&-
	unset ZFS_UNMOUNT_PARALLELISM
	poolexists $POOL && destroy_pool $POOL
	rm -rf $VDEV $MNT $TEST_BASE_DIR/pu_err
}

# Number of mounts of datasets or snapshots in $POOL.
function pool_mounts
{
	mount | awk -v p=$POOL 'index($1, p "/") == 1 || index($1, p "@") == 1 ||
	    $1 == p' | wc -l
}

# Every dataset is mounted and its file has its name.
function verify_imported
{
	typeset name mounted mp

	zfs list -H -o name,mounted,mountpoint -t filesystem -r $POOL |
	    while read -r name mounted mp; do
		[[ $mounted == yes ]] || log_fail "$name is not mounted"
		[[ "$(<$mp/file)" == "$name" ]] || log_fail "$mp/file is wrong"
	done
	log_note "all datasets mounted with their data"
}

function export_import
{
	typeset -i start

	start=$SECONDS
	log_must zpool export $POOL
	log_note "export with ZFS_UNMOUNT_PARALLELISM=" \
	    "${ZFS_UNMOUNT_PARALLELISM:-default} took $((SECONDS - start))s"
	log_must test $(pool_mounts) -eq 0
	log_must zpool import -d $VDEV $POOL
	verify_imported
}

log_assert "zpool export unmounts nested datasets in parallel"
log_onexit cleanup

log_must mkdir -p $VDEV
log_must truncate -s $MINVDEVSIZE $VDEV/disk
log_must zpool create -O mountpoint=$MNT $POOL $VDEV/disk

for t in $(seq 1 $TOP); do
	log_must zfs create $POOL/t$t
	for m in $(seq 1 $MID); do
		log_must zfs create $POOL/t$t/m$m
		for l in $(seq 1 $LEAF); do
			log_must zfs create $POOL/t$t/m$m/l$l
		done
	done
done
# Mounted under t1/m1 but a child of the pool root: ordering must follow
# mountpoints, not dataset names.
log_must zfs create -o mountpoint=$MNT/t1/m1/x $POOL/x
log_must zfs create $POOL/x/y

zfs list -H -o name,mountpoint -t filesystem -r $POOL |
    while read -r ds mp; do
	echo $ds > $mp/file
done
log_must zfs snapshot $POOL/t2/m2@snap
log_must ls $MNT/t2/m2/.zfs/snapshot/snap/file
log_note "$(pool_mounts) mounts in $POOL"

export_import
for nthr in 1 4; do
	export ZFS_UNMOUNT_PARALLELISM=$nthr
	export_import
done
unset ZFS_UNMOUNT_PARALLELISM

busy=$MNT/t3/m3/l3
exec 3<$busy/file
log_mustnot eval "zpool export $POOL 2>$TEST_BASE_DIR/pu_err"
log_must grep -q "cannot unmount '$busy'" $TEST_BASE_DIR/pu_err
log_must poolexists $POOL
log_must ismounted $POOL/t3/m3/l3
log_must ismounted $POOL/t3/m3
log_must ismounted $POOL
exec 3<&-

export_import

log_pass "zpool export unmounts nested datasets in parallel"
