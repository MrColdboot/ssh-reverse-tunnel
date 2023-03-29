#!/usr/bin/env bash
## A script for deploying a temporary reverse SSH tunnel

## Destination path to deploy the script
DEPLOY_PATH=${DEPLOY_PATH:-$HOME/reverse-ssh}

## Name of the script to deploy
SCRIPT_NAME=${SCRIPT_NAME:-reverse-ssh}

## A crontab timespec when to run the job
CRON_TIMESPEC=${CRON_TIMESPEC:-~ * * * *}

## TCP port to transmit the SSH public key before attempting to connect
KEY_XFER_PORT=${KEY_XFER_PORT:-40023}
KEY_XFER_WAIT_TIME=${KEY_XFER_WAIT_TIME:-300}

## Tunnel setup
TUNNEL_REMOTE_PORT=${TUNNEL_REMOTE_PORT:-40022}
TUNNEL_LOCAL_PORT=${TUNNEL_LOCAL_PORT:-22}
TUNNEL_OPENTIME=${TUNNEL_OPENTIME:-60}

## Outgoing SSH connection details
REMOTE_USER=${REMOTE_USER:-root}
REMOTE_HOST=${REMOTE_HOST:-localhost}
REMOTE_PORT=${REMOTE_PORT:-22}

CRONTAB=$(which crontab)
SSH=$(which ssh)


## Gather facts
confirmed=0
exec 3<>/dev/tty
while [ $confirmed == 0 ]; do
	
	read -u 3 -p "Enter the path to deploy the scripts to: [$DEPLOY_PATH] "
	DEPLOY_PATH=`realpath -m "$(eval echo "${REPLY:-$DEPLOY_PATH}")"`

	read -u 3 -p "Enter the cron timespec: [$CRON_TIMESPEC] "
	CRON_TIMESPEC=${REPLY:-$CRON_TIMESPEC}

	read -u 3 -p "Enter the remote user: [$REMOTE_USER] "
	REMOTE_USER=${REPLY:-$REMOTE_USER}
	read -u 3 -p "Enter the remote host: [$REMOTE_HOST] "
	REMOTE_HOST=${REPLY:-$REMOTE_HOST}
	read -u 3 -p "Enter the remote port: [$REMOTE_PORT] "
	REMOTE_PORT=${REPLY:-$REMOTE_PORT}

	read -u 3 -p "Enter the tunnel source (remote) port: [$TUNNEL_REMOTE_PORT] "
	TUNNEL_REMOTE_PORT=${REPLY:-$TUNNEL_REMOTE_PORT}
	read -u 3 -p "Enter the tunnel destination (local) port: [$TUNNEL_LOCAL_PORT] "
	TUNNEL_LOCAL_PORT=${REPLY:-$TUNNEL_LOCAL_PORT}
	read -u 3 -p "Enter the time (in seconds) to sleep once the tunnel is open: [$TUNNEL_OPENTIME] "
	TUNNEL_OPENTIME=${REPLY:-$TUNNEL_OPENTIME}

	read -u 3 -p "Enter the key transfer port: [$KEY_XFER_PORT] "
	KEY_XFER_PORT=${REPLY:-$KEY_XFER_PORT}
	read -u 3 -p "Enter the key transfer wait time: [$KEY_XFER_WAIT_TIME] "
	KEY_XFER_WAIT_TIME=${REPLY:-$KEY_XFER_WAIT_TIME}

	read -u 3 -p "Enter the key filter command: [$KEY_FILTER_CMD] "
	KEY_FILTER_CMD=${REPLY:-$KEY_FILTER_CMD}

	answered=0
	while [ $answered == 0 ]; do
		echo
		echo "Current Settings"
		echo "----------------"
		cat <<- EOT | column -t -s '#'
			DEPLOY_PATH:#"$DEPLOY_PATH"
			CRON_TIMESPEC:#"$CRON_TIMESPEC"
			REMOTE_USER:#"$REMOTE_USER"
			REMOTE_HOST:#"$REMOTE_HOST"
			REMOTE_PORT:#"$REMOTE_PORT"
			TUNNEL_REMOTE_PORT:#"$TUNNEL_REMOTE_PORT"
			TUNNEL_LOCAL_PORT:#"$TUNNEL_LOCAL_PORT"
			TUNNEL_OPENTIME:#"$TUNNEL_OPENTIME"
			KEY_XFER_PORT:#"$KEY_XFER_PORT"
			KEY_XFER_WAIT_TIME:#"$KEY_XFER_WAIT_TIME seconds"
			KEY_FILTER_CMD:#"$KEY_FILTER_CMD"
			EOT
		echo
		read -u 3 -p "Does this look okay? (y/N): "
		case $REPLY in
		[Yy])
			confirmed=1
			answered=1
			;;
		[Nn])
			answered=1
			;;
		*)
			echo "Please enter 'y' or 'n'"
			echo
			;;
		esac
	done
done

## Create a temporary working directory
TMPDIR=`mktemp -d`
trap "rm -Rf $TMPDIR" EXIT

## Generate SSH key-pair
mkdir -p "$TMPDIR/out/ssh"
ssh-keygen -t rsa -b 3072 -f "$TMPDIR/out/ssh/id_rsa" -q -N "" -C "$SCRIPT_NAME"

## Generate script
cat <<EOT >"$TMPDIR/out/$SCRIPT_NAME"
#!/bin/sh
run() {
	ps=\$(ps -xo pid,args | grep -E '^\s+[0-9]+\s+ssh.*-R $TUNNEL_REMOTE_PORT:localhost:$TUNNEL_LOCAL_PORT .* $REMOTE_USER@$REMOTE_HOST' | awk '{print \$1}')
	if [ -n "\$ps" ]; then
		exit
	else
		/bin/sh -c "(${KEY_FILTER_CMD:-cat}) <'$DEPLOY_PATH/ssh/id_rsa.pub' | nc $REMOTE_HOST $KEY_XFER_PORT" || exit
		sleep $KEY_XFER_WAIT_TIME
		ssh -f \\
			-R $TUNNEL_REMOTE_PORT:localhost:$TUNNEL_LOCAL_PORT \\
			-i '$DEPLOY_PATH/ssh/id_rsa' \\
			-p $REMOTE_PORT \\
			-o StrictHostKeyChecking=no \\
			-o UserKnownHostsFile=/dev/null \\
			$REMOTE_USER@$REMOTE_HOST sleep $TUNNEL_OPENTIME
	fi
}

uninstall() {
	if [ \$USER != $USER ]; then
		echo "The uninstall function must be run as user '$USER'" >&2
		exit 1
	fi
	TMPFILE=\$(mktemp)
	trap "rm -f \$TMPFILE" EXIT
	(crontab -l 2>/dev/null | awk "/$SCRIPT_NAME/{next}{print \\\$0}" >\$TMPFILE) || exit 1
	if [ \$(wc -c \$TMPFILE | cut -d ' ' -f 1) == 0 ]; then
		crontab -r
	else
		crontab \$TMPFILE
	fi
	rm -Rf "$(realpath "$DEPLOY_PATH")"
	echo "Uninstall complete!"
}

case \$1 in
uninstall)
	uninstall
	;;
*)
	run
	;;
esac
EOT
chmod +x "$TMPDIR/out/$SCRIPT_NAME"

## Create crontab
crontab -l 2>/dev/null | awk "/$SCRIPT_NAME/{next}{print \$0}" >$TMPDIR/crontab
echo "$CRON_TIMESPEC \"$DEPLOY_PATH/$SCRIPT_NAME\"" >>$TMPDIR/crontab
crontab -T $TMPDIR/crontab 2>/dev/null || exit 1

## Install the script and key
mkdir -p "$DEPLOY_PATH"
cp -r $TMPDIR/out/* "$DEPLOY_PATH" || exit 1

## Install crontab
crontab $TMPDIR/crontab || exit 1

## Display summary
cat <<EOT | tee summary.out

================================================================================
 Summary
================================================================================
   Date: $(date)
   Name: $SCRIPT_NAME
   User: $USER ($UID)
   Host: $(cat /etc/hostname)
   Path: $DEPLOY_PATH
================================================================================
Every:
    $CRON_TIMESPEC
As user:
    $USER ($UID)
And transfer key:
    $(ssh-keygen -l -f $TMPDIR/out/ssh/id_rsa -E md5)
    $(ssh-keygen -l -f $TMPDIR/out/ssh/id_rsa -E sha256)
Using filter command:
    ${KEY_FILTER_CMD:-[None]}
To remote port:
    $KEY_XFER_PORT
Then wait:
    $KEY_XFER_WAIT_TIME seconds
Before connecting to:
    $REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT
And forwarding ports [remote:local]:
    $TUNNEL_REMOTE_PORT:$TUNNEL_LOCAL_PORT
================================================================================
 To uninstall, run:
    '$DEPLOY_PATH/$SCRIPT_NAME uninstall'
================================================================================
  * Verify the cron service is running!
  * Verify the ssh service is running!
  * Verify the system has internet access!
================================================================================
EOT
