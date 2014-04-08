#!/bin/bash
# Copyright 2014 David Spencer, Baildon, West Yorkshire, U.K.
# All rights reserved.  For licence details, see the file 'LICENCE'.
#-------------------------------------------------------------------------------
# buildfunctions.sh - build functions for slackrepo
#   build_package
#   build_ok
#   build_failed
#-------------------------------------------------------------------------------

function build_package
# Build the package for an item
# $1 = itempath
# The built package goes into $SR_TMPOUT, but function build_ok then stores it elsewhere
# Return status:
# 0 = total success, world peace and happiness
# 1 = build failed
# 2 = download failed
# 3 = checksum failed
# 4 = [not used]
# 5 = skipped by hint, or unsupported on this arch
# 6 = SlackBuild returned 0 status, but nothing in $SR_TMPOUT
# 7 = excessively dramatic qa test fail
{
  local itempath="$1"
  local prgnam=${itempath##*/}

  do_hint_skipme $itempath && return 5

  SR_TMPIN=$SR_TMP/sr_IN.$$
  rm -rf $SR_TMPIN
  cp -a $SR_SBREPO/$itempath $SR_TMPIN

  if [ "$OPT_TEST" = 'y' ]; then
    test_slackbuild $itempath || return 7
  fi

  # Fiddle with $VERSION -- usually doomed to failure, but not always ;-)
  VERSION="${INFOVERSION[$itempath]}"
  do_hint_version $itempath
  if [ -n "$NEWVERSION" ]; then
    sed -i -e "s/^VERSION=.*/VERSION=$NEWVERSION/" "$SR_TMPIN/$prgnam.SlackBuild"
    verpat="$(echo ${INFOVERSION[$itempath]} | sed 's/\./\\\./g')"
    INFODOWNLIST[$itempath]="$(echo "${INFODOWNLIST[$itempath]}" | sed "s/$verpat/$NEWVERSION/g")"
    VERSION="$NEWVERSION"
    # (but also leave $NEWVERSION set, to inform verify_src that we upversioned)
  fi

  # Get the source (including check for unsupported/untested)
  verify_src $itempath
  case $? in
    0) # already got source, and it's good
       [ "$OPT_TEST" = 'y' ] && test_download $itempath
       ;;
  1|2) # already got source, but it's bad => get it
       log_verbose -a "Note: cached source is bad"
       download_src $itempath
       verify_src $itempath || { log_error -a "${itempath}: Downloaded source is bad"; build_failed $itempath; return 3; }
       ;;
    3) # not got source => get it
       download_src $itempath
       verify_src $itempath || { log_error -a "${itempath}: Downloaded source is bad"; build_failed $itempath; return 3; }
       ;;
    4) # wrong version => get it
       download_src $itempath
       verify_src $itempath || { log_error -a "${itempath}: Downloaded source is bad"; build_failed $itempath; return 3; }
       ;;
    5) # unsupported/untested
       SKIPPEDLIST="$SKIPPEDLIST $itempath"
       return 5
       ;;
  esac

  # Symlink the source (if any) into the temporary SlackBuild directory
  if [ -n "${INFODOWNLIST[$itempath]}" ]; then
    ln -sf -t $SR_TMPIN/ ${SRCDIR[$itempath]}/*
  fi

  # Work out BUILD
  # Get the value from the SlackBuild
  unset BUILD
  buildassign=$(grep '^BUILD=' $SR_TMPIN/$prgnam.SlackBuild)
  if [ -z "$buildassign" ]; then
    buildassign="BUILD=1"
    log_warning -a "${itempath}: \"BUILD=\" not found in SlackBuild; using 1"
  fi
  eval $buildassign
  if [ "$OP" = 'build' -o "$OPT_DRYRUN" = 'y' ]; then
    # just use the SlackBuild's BUILD
    SR_BUILD="$BUILD"
  else
    # increment the existing BUILD or use the SlackBuild's (whichever is greater)
    oldbuild=$(ls $SR_PKGREPO/$itempath/*.t?z 2>/dev/null | sed -e 's/^.*-//' -e 's/[^0-9]*$//' )
    nextbuild=$(( ${oldbuild:-0} + 1 ))
    if [ "$nextbuild" -gt "$BUILD" ]; then
      SR_BUILD="$nextbuild"
    else
      SR_BUILD="$BUILD"
    fi
  fi

  # Process other hints for the build (uidgid, options, makeflags, answers)
  do_hint_uidgid $itempath
  if [ "${HINT_makej1[$itempath]}" = 'y' ]; then
    tempmakeflags="MAKEFLAGS='-j1'"
    USE_NUMJOBS=" -j1 "
  else
    tempmakeflags="MAKEFLAGS='$SR_NUMJOBS'"
    USE_NUMJOBS=" $SR_NUMJOBS "
  fi
  options=""
  [ "${HINT_options[$itempath]}" != '%NONE%' ] && options="${HINT_options[$itempath]}"
  SLACKBUILDCMD="sh ./$prgnam.SlackBuild"
  [ -n "$tempmakeflags" -o -n "$options" ] && SLACKBUILDCMD="env $tempmakeflags $options $SLACKBUILDCMD"
  [ -n "${HINT_answers[$itempath]}" ] && SLACKBUILDCMD="cat ${HINT_answers[$itempath]} | $SLACKBUILDCMD"

  # Build it
  SR_TMPOUT=$SR_TMP/sr_OUT.$$
  rm -rf $SR_TMPOUT
  mkdir -p $SR_TMPOUT
  export \
    ARCH=$SR_ARCH \
    BUILD=$SR_BUILD \
    TAG=$SR_TAG \
    TMP=$SR_TMP \
    OUTPUT=$SR_TMPOUT \
    PKGTYPE=$SR_PKGTYPE \
    NUMJOBS=$USE_NUMJOBS
  log_normal -a "Running SlackBuild: $SLACKBUILDCMD ..."
  ( cd $SR_TMPIN; eval $SLACKBUILDCMD ) >>$ITEMLOG 2>&1
  stat=$?
  unset ARCH BUILD TAG TMP OUTPUT PKGTYPE NUMJOBS
  if [ $stat != 0 ]; then
    log_error -a "${itempath}: $prgnam.SlackBuild failed (status $stat)"
    build_failed $itempath
    return 1
  fi

  # Make sure we got *something* :-)
  pkglist=$(ls $SR_TMPOUT/*.t?z 2>/dev/null)
  if [ -z "$pkglist" ]; then
    # let's get sneaky
    logpkgs=$(grep "Slackware package .* created." $ITEMLOG | cut -f3 -d" ")
    if [ -n "$logpkgs" ]; then
      for pkgpath in $logpkgs; do
        if [ -f $SR_TMPIN/README -a -f $SR_TMPIN/$prgnam.info ]; then
          # it's probably an SBo SlackBuild, so complain and don't retag
          log_warning -a "${itempath}: Package should have been in \$OUTPUT: $pkgpath"
          mv $pkgpath $SR_TMPOUT
        else
          pkgnam=${pkgpath##*/}
          currtag=$(echo $pkgnam | rev | cut -f1 -d- | rev | sed 's/^[0-9]*//' | sed 's/\..*$//')
          if [ "$currtag" != "$SR_TAG" ]; then
            # retag it
            pkgtype=$(echo $pkgnam | rev | cut -f1 -d- | rev | sed 's/^[0-9]*//' | sed 's/^.*\.//')
            mv $pkgpath $SR_TMPOUT/$(echo $pkgnam | sed 's/'$currtag'\.'$pkgtype'$/'$SR_TAG'.'$pkgtype'/')
          else
            mv $pkgpath $SR_TMPOUT/
          fi
        fi
      done
      pkglist=$(ls $SR_TMPOUT/*.t?z 2>/dev/null)
    else
      log_error -a "${itempath}: No packages were created"
      build_failed $itempath
      return 6
    fi
  fi

  if [ "$OPT_TEST" = 'y' ]; then
    test_package $itempath $pkglist || { build_failed $itempath; return 7; }
  fi

  build_ok $itempath  # \o/
  return 0
}

#-------------------------------------------------------------------------------

function build_ok
# Log, cleanup and store the packages for a build that has succeeded
# $1 = itempath
# Return status: always 0
{
  local itempath="$1"
  local prgnam=${itempath##*/}

  rm -rf $SR_TMPIN

  if [ "$OPT_DRYRUN" = 'y' ]; then
    # put the package into the special dryrun repo
    mkdir -p $DRYREPO/$itempath
    rm -rf $DRYREPO/$itempath/*
    mv $SR_TMPOUT/* $DRYREPO/$itempath/
  else
    # put it into the real package repo
    mkdir -p $SR_PKGREPO/$itempath
    rm -rf $SR_PKGREPO/$itempath/*
    mv $SR_TMPOUT/* $SR_PKGREPO/$itempath/
  fi
  rm -rf $SR_TMPOUT

  # This won't always kill everything, but it's good enough for saving space
  rm -rf $SR_TMP/${prgnam}* $SR_TMP/package-${prgnam}

  msg="$OP OK"
  [ "$OPT_DRYRUN" = 'y' ] && msg="$OP --dry-run OK"
  log_success -a ":-) $itempath $msg (-:"
  OKLIST="$OKLIST $itempath"
  return 0
}

#-------------------------------------------------------------------------------

function build_failed
# Log and cleanup for a build that has failed
# $1 = itempath
# Return status: always 0
{
  local itempath="$1"
  local prgnam=${itempath##*/}

  rm -rf $SR_TMPIN $SR_TMPOUT
  # but don't remove files from $SR_TMP, they can help to diagnose why it failed

  msg="$OP FAILED"
  log_error -n -a ":-( $itempath $msg )-:"
  log_error -n "See $ITEMLOG"
  errorscan_itemlog | tee -a $MAINLOG
  FAILEDLIST="$FAILEDLIST $itempath"
  return 0
}
