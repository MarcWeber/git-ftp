#!/bin/sh
set -e

# KISS version of git-ftp (original code: https://github.com/resmo/git-ftp)
# LICENSE: GPLv3

# General config
DEFAULT_PROTOCOL="ftp"
DEPLOYED_SHA1_FILE=".git-ftp.log"
LCK_FILE=".git/`basename $0`.lck"
REMOTE_LCK_FILE="`basename $0`.lck"
SYSTEM=`uname`

# ------------------------------------------------------------
# Defaults
# ------------------------------------------------------------

# remote path should end with /
#  FTP (default)	host.example.com[:<port>][/<remote path>]
#  FTP		ftp://host.example.com[:<port>][/<remote path>]
#  SFTP		sftp://host.example.com[:<port>][/<remote path>]
#  FTPS		ftps://host.example.com[:<port>][/<remote path>]
#  FTPES		ftpes://host.example.com[:<port>][/<remote path>]

URL="ftp://host.example.com[:<port>][/<remote path>]"

# WILL BE SET automatically
REMOTE_PROTOCOL=""
REMOTE_HOST=""
REMOTE_USER=""
REMOTE_PASSWD=""
REMOTE_PATH=""
REMOTE_DELETE_CMD="-DELE "
REMOTE_CMD_OPTIONS="-s"
VERBOSE=0
IGNORE_DEPLOYED=0
DRY_RUN=0
FORCE=0
ACTION=""
ENABLE_REMOTE_LCK=0
LOG_CACHE=""
SCOPE=""
TARGET_SHA1="$(git rev-list -1 HEAD)"
TMP_FILE=./TMP_FILE


die(){ echo "$@"; exit 1; }

. ./git-ftp-minimal.config || die "local config not found"

handle_remote_protocol_options() {
  # SFTP uses a different remove command and uses absolute paths
  [ "$REMOTE_PROTOCOL" != "sftp" ] || REMOTE_DELETE_CMD="rm /"
  # Options for curl if using FTPES
  [ "$REMOTE_PROTOCOL" != "ftpes" ] || REMOTE_CMD_OPTIONS="$REMOTE_CMD_OPTIONS --ftp-ssl -k"
}

set_remote_protocol() {

  [ -n $URL ] || [ -z "$SCOPE" ] || URL="`git config --get git-ftp.$SCOPE.url`"
  [ -n $URL ] || URL="`git config --get git-ftp.url`"
  REMOTE_HOST=`expr "$URL" : ".*://\([a-z0-9\.:-]*\).*"`
  [ -n $REMOTE_HOST ] || REMOTE_HOST=`expr "$URL" : "^\([a-z0-9\.:-]*\).*"`
  [ -n $REMOTE_HOST ] || print_error_and_die "Remote host not set" $ERROR_MISSING_ARGUMENTS

  # Split protocol from url
  REMOTE_PROTOCOL=`echo "$URL" | egrep '^(ftp|sftp|ftps|ftpes)://.*' | cut -d ':' -f 1`

  # Protocol found?
  [ -n $REMOTE_PROTOCOL ] || die "unkown protocol!"
  REMOTE_PATH=`echo "$URL" | cut -d '/' -f 4-`
  handle_remote_protocol_options

}

set_default_curl_options() {
  args=($REMOTE_CMD_OPTIONS)
  if [ ! -z $REMOTE_USER ]; then
    args+=(--user "$REMOTE_USER":"$REMOTE_PASSWD")
  else
    args+=(--netrc)
  fi
  args+=(-#)
}

upload_file() {
  echo "uploading $@"
  if [ -n "$TRY_RUN" ]; then
    echo "dry run - doing nothing"
  else
    SRC_FILE="$1"
    DEST_FILE="$2"
    if [ -z $DEST_FILE ]; then
      DEST_FILE=$SRC_FILE
    fi
    set_default_curl_options
    args+=(-T "$SRC_FILE")
    args+=(--ftp-create-dirs)
    args+=("$REMOTE_PROTOCOL://$REMOTE_HOST/${REMOTE_PATH}${DEST_FILE}")
    curl "${args[@]}"
  fi
}

remove_file() {
  echo "removing $@"
  if [ -n "$TRY_RUN"]; then
    echo "dry run - doing nothing"
  else
    FILENAME="$1"
    set_default_curl_options
    args+=(-Q "${REMOTE_DELETE_CMD}${REMOTE_PATH}${FILENAME}")
    args+=("$REMOTE_PROTOCOL://$REMOTE_HOST")
    if [ "$REMOTE_CMD_OPTIONS" = "-v" ]; then
      curl "${args[@]}"
    else
      curl "${args[@]}" > /dev/null 2>&1 || die "Could not delete ${REMOTE_PATH}${FILENAME}, continuing..."
    fi
  fi
}

get_file_content() {
  SRC_FILE="$1"
  set_default_curl_options
  args+=("$REMOTE_PROTOCOL://$REMOTE_HOST/${REMOTE_PATH}${SRC_FILE}")
  curl "${args[@]}"
}

run(){
  changed="$1"
  ACTIONS=""
  # verify that nobody changed the hash on the server
  while read line; do
    M=`echo "$line" | cut -f 1`
    F=`echo "$line" | cut -f 2`
    case "$M" in
      D|M)
        echo "was file $F touched on remote location?"
	get_file_content "$F" > "$TMP_FILE"
        md5_remote="$(cat $TMP_FILE | md5sum)"
        md5_local_target="$(git show "$TARGET_SHA1:$F" | md5sum )"
        md5_local_deployed="$(git show "$DEPLOYED_SHA1:$F" | md5sum )"
        if [ "$md5_remote" == "$md5_local_target" ]; then
	  echo "skippping $F, already up to date"
	else
          # if the file is not on the remote server yet
          [  "$md5_remote" == "$md5_local_deployed" ] || {
              echo -n "$F on server was changed? continue ? [y/n] (md5 local: $md5_local_deployed -> $md5_local_target remote: $md5_remote, downloaded to $TMP_FILE)"
              read reply
              [ "$reply" = "y" ] || die "aborting"
              echo "continuing"
          }
          ACTIONS="${ACTIONS}\n$line"
        fi
      ;;
      A)
        # file must not exist!
        
	echo "does $F already exist on sever?"
        if get_file_content "$F" > "$TMP_FILE"; then
          # file exists, check hash
          md5=$(cat "$TMP_FILE" | md5sum)
          md5_local="$(git show "$TARGET_SHA1:$F" | md5sum)"
          if [ "$md5_local" == "$md5" ]; then
            rm "$TMP_FILE"
            echo "$F already found on server - md5sums match"
          else
            die "not overriding file $F on sever which has a different hash. local: $md5_local, remote: $md5, server version was downloaded into: $TMP_FILE"
          fi
        else
          rm "$TMP_FILE"
          # expected. file did not exist ?
          ACTIONS="$(echo "$ACTIONS"; echo "$line")"
        fi
      ;;
      *) [ "$line" == "" ] || die "unkown mode '$M' (line: '$line')";;
    esac
  done <<< "$changed" 

  echo "running actions\n$ACTIONS"

  while read line; do
    echo "processing: $line"
    M=`echo "$line" | cut -f 1`
    F=`echo "$line" | cut -f 2`
    case "$M" in
      D)
        remove_file "$F"
      ;;
      M|A)
        git show "$TARGET_SHA1:$F" | upload_file - "$F"
      ;;
      *) [ "$line" == "" ] || die "unkown mode '$M' (line: '$line')";;
    esac
  done <<< "$changed" 
}

while [ -n "$1" ]; do
  case "$1" in
    -x) shift; set -x;;
    --dry-run)
        shift; TRY_RUN=1;;
    --help)
      cat << EOF
      usage: 
        $0 [-x] [--dry-run] --inital (upload all files and sha1)
        $0 [-x] [--dry-run] --upload-sha1 SHA (upload sha)
        $0 [-x] [--dry-run] --sync           (synchronize from sha1 stored on server targeting \$TARGET_SHA1)
      Files are uploaded / removed only if nobody touched them on the server. This is a bit slower - but also safest.
EOF
      die "help shown"
    ;;
    --upload-sha1)
      shift
      set_remote_protocol
      [ -n "$1" ] || die "no second argument, sha expected"
      echo $1 | upload_file - $DEPLOYED_SHA1_FILE
      shift
      exit 0
    ;;
    --initial)
      shift
      set_remote_protocol
      run "$(git ls-files | sed "s/^/A\t/" | filter)"
      echo "$TARGET_SHA1" | upload_file - $DEPLOYED_SHA1_FILE

      exit 0
    ;;
    --sync)
      shift
      set_remote_protocol
      DEPLOYED_SHA1="`get_file_content $DEPLOYED_SHA1_FILE`"
      [ -n "$DEPLOYED_SHA1" ] || die "no DEPLOYED_SHA1 ?"
      git diff --name-status $DEPLOYED_SHA1 $TARGET_SHA1
      run "`git diff --name-status $DEPLOYED_SHA1 2>/dev/null | filter`" || die "git diff --name-status $DEPLOYED_SHA1_FILE failed - invalid sha1 ?!"
      echo "$TARGET_SHA1" | upload_file - $DEPLOYED_SHA1_FILE

      exit 0
    ;;
    *)
      die "unkown arg \`$1'"
  esac
done

die "no command given"
