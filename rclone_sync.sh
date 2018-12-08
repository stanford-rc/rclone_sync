#!/bin/bash
# vim: ts=4 sw=4 noet

#  Google Drive sync tool, using SLURM and rclone.  Last Updated 2018-12-07.
#  Written by A. Karl Kornel <akkornel@stanford.edu>

#  Copyrght (C) 2018 The Board of Trustees of the Leland Stanford Junior
#+ University.  The contents of this file are licensed under the GNU General
#+ Public License, Version 3.  The text of this license is included in the
#+ source repository (in the file named 'LICENSE') and is also available at the
#+ URL https://www.gnu.org/licenses/gpl-3.0.en.html

#  NEW USERS:
#
#  First of all, make sure that you are using the shared copy of this script.
#  **Do not make your own copy!**
#  
#  To use the script, run it directly.
#  (In other words, run it like any other script!)
#
#  The script takes one argument: The directory to back up.
#  So, to sync the directory "blah" to Google Drive, you would run like so:
#    ./scriptname.sh blah
#
#  The script will do some checks, and then submit itself as a SLURM job.
#  The script does support preemption, so it can be requeued and restarted as
#+ many times as needed.
#  The script has a time limit; if it needs more time to complete the backup,
#+ it will resubmit itself.
#  Once a backup has completed, it will email you, and submit itself to re-run
#+ tomorrow.
#
#  NOTE: The script has protections to make sure that a directory is not being
#+ synced multiple times simultaneously.  As a side-effect of this, you can not
#+ use this tool to sync different directories which have the same name.

#  NEW LABS:
#
#  New labs should refer to the 'README.md' file (part of the source
#+ repository) for instructions on how to set this up for your lab.

#
# SLURM SETTINGS START HERE
#

#  The partition to use.  If possible, choose a preemptable partition.
#SBATCH --partition owners

#  Use one CPU core, 1G RAM, and support sharing resources (if allowed).
#SBATCH --ntasks 1
#SBATCH --cpus-per-task 1
#SBATCH --mem-per-cpu 1G
#SBATCH --oversubscribe

#  Limit runtime to 2 hours, but allow to run for only 10 minutes if that gives
#+ us an opportunity to run at all.  We'll reschedule ourselves if needed.
#SBATCH --time 2:00:00
#SBATCH --time-min 0:10:00

#  Let us know when we're going to be killed.
#  Also, ask SLURM to only let one of us be running at a time.
#SBATCH --signal B:USR1@30
#SBATCH --dependency singleton

#  We support being kicked off of a node.
#SBATCH --requeue

#  Only email if the job fails (which means it won't reschedule).
#SBATCH --mail-type FAIL

#  NOTE: These two lines are disabled by default!  You can "enable" them by
#+ deleting one of the # characters at the start of the line.
#  Stop creating .out files for each SLURM job.  Only do this if things work.
##SBATCH --error /dev/null
##SBATCH --output /dev/null

#
# LAB-SPECIFIC SETTINGS START HERE
#

#  Code is allowed after this point.  No more #SBATCH lines will be recognized.

#  This is the name of the rclone remote that refers to your lab's Team Drive.
#+ NOTE that it is not the same thing as your actual team drive name, it's just
#+ an identifier.
remote_name=quakedrive

#  This is the path, relative to your Team Drive's root, where backups should
#+ go.  Note that the entire path is in quotes, so spaces etc. are allowed.
#  Use the forward-slash character (a / character) as the path separator.
#  NOTE: Your path should neither start nor end with a forward-slash!
drive_path='Sherlock Backupss'

#
# CODE STARTS HERE
#

# DEBUG can be set to 1 outside of the script, to enable debug logs.
DEBUG=${DEBUG:=0}
if [ $DEBUG -eq 1 ]; then
	echo 'Debug alive'
fi

# We need TMPDIR to be set.  If it's not, default to '/tmp'
TMPDIR=${TMPDIR:=/tmp}

# Combine standard output and standard error
exec 2>&1


#  Before we have any real code, define a function to email or output an error.
function mail_or_print {
	#  $1 = The body of the email
	#  $2 = The subject line of the email
	if [ $DEBUG -eq 1 ]; then
		echo 'In mail_or_print'
	fi

	#  If we are in SLURM, then we need to send an email to the user.
	#  Otherise, simply print the subject and message to the user.
	if [ ${SLURM_JOB_ID:=0} -ne 0 ]; then
		if [ $DEBUG -eq 1 ]; then
			echo 'Sending email'
		fi
		echo "${1}" | mail -s "${2}" $USER
	else
		echo "${2}"
		echo "${1}"
	fi
	return 0
}

#  Next, we need a set of functions to tell us if a particular rclone exit code
#+ has a partiuclar meaning.  We know exit code zero is "completed
#+ successfully", but what about the others?
#  NOTE: For these functions, returning true means returning zero, so that
#+ the function's result can be used directly in an `if` statement.

# This function returns true 
function rclone_exit_failed {
	if [ $DEBUG -eq 1 ]; then
		echo "In rclone_exit_failed with exit code ${1}"
	fi
	case $1 in
		1)
			return 0
			;;
		2)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

#  This function returns true if the provided exit code means something was not
#+ found, either on our end of the transfer or on the remote end.
function rclone_exit_notfound {
	if [ $DEBUG -eq 1 ]; then
		echo "In rclone_exit_notfound with exit code ${1}"
	fi
	case $1 in
		3)
			return 0
			;;
		4)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

#  This function returns true if the error is due to a temporary condition,
#+ and trying again later may resolve the issue.
function rclone_exit_temporary {
	if [ $DEBUG -eq 1 ]; then
		echo "In rclone_exit_temporary with exit code ${1}"
	fi
	case $1 in
		5)
			return 0
			;;
		8)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

#  This function returns true if the error is some sort of permanent failure.
function rclone_exit_permanent {
	if [ $DEBUG -eq 1 ]; then
		echo "In rclone_exit_permanent with exit code ${1}"
	fi
	case $1 in
		6)
			return 0
			;;
		7)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

#  Finally, define a set of functions that will send an alert on a particular
#+ rclone condition, and then exit.
#  TIP: 'rclone_exit_' -> "Did rclone exit because of ..."
#  TIP: 'exit_rclone_' -> "Exit because of rclone issue ..."

#  This function handles alerting when rclone exited because of a generic, non-
#+ retryable failure.
#  $1 is the command run.
#  $2 is the command output.
function exit_rclone_failed {
	if [ $DEBUG -eq 1 ]; then
		echo "In exit_rclone_failed"
		echo "Command is ${1}"
	fi
	IFS='' read -r -d '' error_message <<-EOF
	There was a problem running rclone.  This is either because of a local problem, or because of some other problem that rclone hasn't otherwise classified.  Either way, this program will not work until the underlying problem is fixed.

	The rclone command run was: ${1}
	Here is the output from rclone:
	${2}
EOF
	error_subject='rclone failure [ACTION REQUIRED]'
	mail_or_print "${error_message}" "${error_subject}"
	exit 1
}

#  This function handles alerting when rclone exited because something wasn't
#+ found.
#  $1 is the command run.
#  $2 is the command output.
function exit_rclone_notfound {
	if [ $DEBUG -eq 1 ]; then
		echo "In exit_rclone_notfound"
		echo "Command is ${1}"
	fi
	IFS='' read -r -d '' error_message <<-EOF
	There was a problem running rclone.  One of the paths wasn't found, either a local path, or a remote path.  Either way, this program will not work until the underlying problem is fixed.

	The rclone command run was: ${1}
	Here is the output from rclone:
	${2}
EOF
	error_subject='rclone path not found [ACTION REQUIRED]'
	mail_or_print "${error_message}" "${error_subject}"
	exit 1
}

#  This function handles alerting when rclone exited because of some sort of
#+ permanent error.
#  $1 is the command run.
#  $2 is the command output.
function exit_rclone_permanent {
	if [ $DEBUG -eq 1 ]; then
		echo "In exit_rclone_permanent"
		echo "Command is ${1}"
	fi
	IFS='' read -r -d '' error_message <<-EOF
	There was a problem running rclone.  The remote service reported some sort of permanent error.  This is an error that cannot be fixed by just waiting around.  Instead, some action must be taken in order to fix things.  This program will not work until the problem is fixed.

	The rclone command run was: ${1}
	Here is the output from rclone:
	${2}
EOF
	error_subject='rclone remote permanent error [ACTION REQUIRED]'
	mail_or_print "${error_message}" "${error_subject}"
	exit 1
}

#  This function handles alerting when rclone exited because of some sort of
#+ temporary error.  This is actually kindof weird, because the "mail" part of
#+ `mail_or_print` probably won't be used; when running in a batch job, we'll
#+ just resubmit ourselves with a small delay.
#  $1 is the command run.
#  $2 is the command output.
function exit_rclone_temporary {
	if [ $DEBUG -eq 1 ]; then
		echo "In exit_rclone_temporary"
		echo "Command is ${1}"
	fi
	IFS='' read -r -d '' error_message <<-EOF
	There was a problem running rclone.  Too many remote operations have been performed, and we have been asked to wait until a later time before doing any more work.

	There is no specific problem to be fixed here.  Instead, just wait a while and re-run the program.

	The rclone command run was: ${1}
	Here is the output from rclone:
	${2}
EOF
	error_subject='rclone remote temporary error [TRY AGAIN LATER]'
	mail_or_print "${error_message}" "${error_subject}"
	exit 1
}


# OMG
# Now we can actually DO STUFF!!!!!


#  Make sure we actually have arguments
if [ $# -ne 1 ]; then
	echo 'This script got the wrong number of arguments!'
	echo 'You should be running this script with one argument: The name of a file or directory to sync.'
	echo "For example: $0 some_directory"
	exit 1
fi

#  Now, make sure we have rclone.
#  NOTE: We can't do the `module load` in a sub-shell.  The reason is, `module
#+ load` changes the environment, and environment changes in a subshell do not
#+ propagate up to us.
if [ $DEBUG -eq 1 ]; then
	echo "Loading modules: system rclone/1.39"
fi
module load system rclone/1.39 2>&1
exit_code=$?
if [ $exit_code -ne 0 ]; then
	IFS='' read -r -d '' error_message <<EOF
The rclone (version 1.39) module, and the system module (which rclone 1.39 requires) could not be loaded.  This either means a problem with your configuration (if you're using a non-default Module program), or the rclone version 1.39 module may be gone (possibly replaced by a newer version?).  Either way, this program will not work until the problem is resolved and the script is updated.
EOF
	error_subject="rclone module load problem [ACTION REQUIRED]"
	mail_or_print "${error_message}" "${error_subject}"
	if [ $DEBUG -eq 1 ]; then
		echo 'ML output:'
		echo $ml_output
	fi
	exit 1
fi

# Next, check that we have a "quakedrive" configuration.
rclone_command=( rclone config show "${remote_name}" )
if [ $DEBUG -eq 1 ]; then
	echo "Checking for config ${remote_name}"
	echo "command: ${rclone_command[@]}"
fi
rclone_output=$("${rclone_command[@]}" 2>&1)
exit_code=$?
if [ $DEBUG -eq 1 ]; then
	echo "command output: ${rclone_output}"
fi
# No exit processing is needed here, because we're not doing remote calls.
if [ $exit_code -ne 0 ]; then
	IFS='' read -r -d '' error_message <<EOF
Your rclone configuration is missing a "$remote_name" remote.  That normally means that you need to do some setup work before running this job.  This program will not work until the remote is set up.  Check with your Lab Manager, or a lab-mate, for information on how to set up the remote!

For reference, your job was attempting to back up this path: ${1}
The above path is relative to the following location: ${PWD}
EOF
	error_subject='rclone configuration problem [ACTION REQUIRED]'
	mail_or_print "${error_message}" "${error_subject}"
	exit 1
fi

#  Now, make sure the source path is accessible.
if [ $DEBUG -eq 1 ]; then
	echo "Checking source path: ${1}"
fi
stat $1 > /dev/null 2>&1
exit_code=$?
if [ $exit_code -ne 0 ]; then
	IFS='' read -r -d '' error_message <<EOF
The source path "$1" is not accessible.  It may be that the directory has been moved, or renamed.  Or maybe you did not provide a source path?  (It should be the first argument after the script.)  Either way, this program will not work anymore.  You should try re-submitting it with a new path.

For reference, the source path above was relative to the following location: ${PWD}
EOF
	error_subject='rclone source path problem [ACTION REQUIRED]'
	mail_or_print "${error_message}" "${error_subject}"
	if [ $DEBUG -eq 1 ]; then
		echo 'stat output:'
		stat $1 2>&1
	fi
	exit 1
fi

#  NOTE: This is the first point where we start making remote calls, and so we
#+ need to check on the exit code, because we could be rate-limited.

#  Check the remote still exists
rclone_command=( rclone ls "${remote_name}:" --max-depth 1 )
if [ $DEBUG -eq 1 ]; then
	echo 'Checking destination path'
	echo "command: ${rclone_command[@]}"
fi
rclone_output=$("${rclone_command[@]}" 2>&1)
exit_code=$?
if rclone_exit_temporary "${exit_code}"; then
	# If we are running interactively, then just ask the user to wait.
	# Otherwise, try running again in 15+ minutes.
	if [ ${SLURM_JOB_ID:=0} -eq 0 ]; then
		exit_rclone_temporary "${rclone_command[*]}" "${rclone_output}"
	else
		exec sbatch --quiet --job-name "Backup ${1}" --begin 'now+15minutes' $0 $@
	fi
fi
if rclone_exit_failed "${exit_code}"; then
	exit_rclone_failed "${rclone_command[*]}" "${rclone_output}"
fi
if rclone_exit_notfound "${exit_code}"; then
	exit_rclone_notfound "${rclone_command[*]}" "${rclone_output}"
fi
if rclone_exit_permanent "${exit_code}"; then
	exit_rclone_permanent "${rclone_command[*]}" "${rclone_output}"
fi

#  Check the base directory still exists
rclone_command=(rclone ls "${remote_name}:${drive_path}" --max-depth 1)
if [ $DEBUG -eq 1 ]; then
	echo 'Checking destination base path'
	echo "command: ${rclone_command[@]}"
fi
rclone_output=$("${rclone_command[@]}" 2>&1)
exit_code=$?
if rclone_exit_temporary "${exit_code}"; then
	# If we are running interactively, then just ask the user to wait.
	# Otherwise, try running again in 15+ minutes.
	if [ ${SLURM_JOB_ID:=0} -eq 0 ]; then
		exit_rclone_temporary "${rclone_command[*]}" "${rclone_output}"
	else
		exec sbatch --quiet --job-name "Backup ${1}" --begin 'now+15minutes' $0 $@
	fi
fi
if rclone_exit_failed "${exit_code}"; then
	exit_rclone_failed "${rclone_command[*]}" "${rclone_output}"
fi
if rclone_exit_notfound "${exit_code}"; then
	exit_rclone_notfound "${rclone_command[*]}" "${rclone_output}"
fi
if rclone_exit_permanent "${exit_code}"; then
	exit_rclone_permanent "${rclone_command[*]}" "${rclone_output}"
fi

#  The directories all exist remotely, and `rclone sync` will take care of
#+ making everything else we need, so we should now be good to go!
#  NOTE: We do not print "good to go" unless we are running interactively.
#  This is to reduce unnecessary output noise.

#  If the user is running this interactively, it's time to submit our job.
#  NOTE: This is the only time we'll run sbatch without `--quiet`.
if [ ${SLURM_JOB_ID:=0} -eq 0 ]; then
	cat - <<EOF
Good to go!
Attempting to submit a job.
After this, you will either get a job ID number, or an error.
If you get a job ID number, all further messages should come to you by email!
EOF
	exec sbatch --job-name="Backup ${1}" --begin=now $0 $@
fi


# If we're here, then we are running inside a job.

#  Assemble the remote path.
remote_path="${remote_name}:${drive_path}/${USER}/${1}"
if [ $DEBUG -eq 1 ]; then
	echo "Using remote_path ${remote_path}"
fi

#  We'll be running rclone in a subshell.  With a subshell, variables from the
#+ parent are copied into the child, but then the parent has no visibility
#+ into what the child's vars are.
#  So, we'll need to capture subshell output into a separate temp file.
rclone_pid=0
rclone_output_file="${TMPDIR}/rclone.${SLURM_JOBID}.out"
if [ $DEBUG -eq 1 ]; then
	echo "rclone output will be sent to path ${rclone_output_file}"
fi

#  We also need to start looking out for our job being warned about
#+ impending killing.  We'll get a USR1 signal, which we'll need to trap.
function signal_usr1 {
	if [ $DEBUG -eq 1 ]; then
		echo 'Received USR1 signal.  Our time has run out.'
	fi

	# Since we'll be killing rclone, unlink our temp file.
	if [ -f ${rclone_output_file} ]; then
		rm ${rclone_output_file}
	fi

	#  Kill the rclone process, and then requeue ourselves.
	#  NOTE: We use `requeue` here so that all of the executions appear under
	#+ the same jobid, which helps with future lookups via `sacct`.
	kill $rclone_pid
	exec scontrol requeue ${SLURM_JOBID}
}

#  We also need to be on the lookout for Control-C (SIGINT); when we receive
#+ it, we need to kill the chiild process.
function signal_int {
	if [ $DEBUG -eq 1 ]; then
		echo 'Received INT signal.  Killing child process and cleaning up.'
	fi

	# Since we'll be killing rclone, unlink our temp file.
	if [ -f ${rclone_output_file} ]; then
		rm ${rclone_output_file}
	fi

	# Kill the rclone process, and then exit ourselves.
	kill $rclone_pid
	exit 1
}

#  All our checks look good!  Let's try running things.

#  This part gets interesting.  We're going to run rclone via a subshell.
#  Vars from the parent shell are present in the subshell, but we can't access
#+ vars created in the subshell.  So, we'll need an output file.
#  NOTE: Since a function takes its own arguments, we need to pass through the
#+ arguments we got on the command line.
trap "signal_usr1 $@" USR1
trap "signal_int $@" INT
if [ $DEBUG -eq 1 ]; then
	echo "Running rclone sync '$1' '${remote_path}'"
fi
(
	exec 1>${rclone_output_file} 2>&1
	exec rclone sync "${1}" "${remote_path}"
) &

#  Get the process ID of the rclone subshell
rclone_pid=$!

#  Wait for rclone to exit, or for something else to happen
if [ $DEBUG -eq 1 ]; then
	echo "rclone launched with PID ${rclone_pid}.  Waiting..."
fi
wait $rclone_pid
exit_code=$?

# Read in the rclone output, in case we have to send an error message.
rclone_output=$(cat ${rclone_output_file})

#  rclone has exited, and we're not dead!  What happened?
if rclone_exit_temporary "${exit_code}"; then
	#  We are not running interactively now, so our next action is always going
	#+ to be to resubmit ourselves.
	exec sbatch --quiet --job-name "Backup ${1}" --begin 'now+15minutes' $0 $@
fi
if rclone_exit_failed "${exit_code}"; then
	exit_rclone_failed "${rclone_command[*]}" "${rclone_output}"; exit $?
fi
if rclone_exit_notfound "${exit_code}"; then
	exit_rclone_notfound "${rclone_command[*]}" "${rclone_output}"; exit $?
fi
if rclone_exit_permanent "${exit_code}"; then
	exit_rclone_permanent "${rclone_command[*]}" "${rclone_output}"; exit $?
fi

# We got this far, which must mean that rclone completed!  Wooo!
if [ $DEBUG -eq 1 ]; then
	echo "Sync complete!  Sending mail and scheduling to run again tomorrow."
fi
IFS='' read -r -d '' completion_message <<EOF
Your backup of path ${1} has been completed without errors!

The output of the \`rclone\` command is attached.  Please check it for problems.
EOF
echo "${completion_message}" | mail -s "Backup completed for ${1}" -a ${rclone_output_file} ${USER}

# Clean up the rclone output file
rm ${rclone_output_file}

# Submit ourselves to run tomorrow.
exec sbatch --quiet --job-name "Backup ${1}" --begin 'now+1day' $0 $@
