This script is a tool which wraps `rclone`, managing recurring `rclone sync`
executions on a local directory tree.

_Why should I use this, instead of just running `rclone`?_

Remembering to back things up is not easy.  If it is not done for you
automatically, then it probably won't be done.

Also, running `rclone` in an HPC environment can be tricky:  In some
environments, running a long-running program on a login node will result in
your session being killed.  If you submit a job, you have to decide how much
runtime to request; if you exceed your allocation, your job is killed.

This tool tries to do it all for you:

* You run it manually, but only the first time: After that, it runs as a
  compute job, so you can go and do something else.

* Before starting, it checks to see if the necessary configuration is present.
  For recurring jobs, it checks that the source directory is still present.

* If you run into Google Drive rate limits, it will resubmit itself to run
  after a delay.

* If you run into a permanent problem, it emails you, letting you know about
  the problem and providing advise on how to resolve it.

* If the compute job exceeds its runtime, it resubmits itself to run again
  ASAP, so that the sync can continue.

* Once a sync is successful, it will resubmit itself to run again tomorrow.

# New User Setup

If you are a new person in a lab that is using this script, **stop here**.
The script that is available in this repository is not ready for immediate use.

Instead, contact your Lab Manager, your resident Data Scientist, or one of your
lab-mates to learn the location of the already-configured script, and how to
use it.

# New Lab Setup

If you are a new lab, welcome!

To begin, clone this repository to your compute environment (where the work
will be performed).  Once you have the [rclone\_sync.sh](rclone_sync.sh) script
on your local system, you should check that you meet the below prerequisites,
and modify your script accordingly.

## Prerequisites

Before you do anything with this script, you will need the following
prerequisites in your compute environment:

* **SLURM**.  This software was tested against SLURM 18.08, and should work
  with older versions.  The only SLURM commands used are `sbatch` (to submit
  compute jobs to run later) and `scontrol requeue` (to requeue jobs that are
  at the end of their runtime allocation).

* **Cluster Email**.  When the script has something to tell the user, it uses
  the `mail` command.  Since it doesn't know the user's email address, it does
  `mail $USER`.  Your cluster systems will need to be able to convert that into
  the user's actual email address.

* **Lmod**.  This software uses the `module load` command to load rclone.  If
  you use a different module system, you'll need to change that command.

* **rclone**.  rclone is what does the real work.  We load modules `system` and
  `rclone/1.39`.  If you use different modules for rclone, you will need to
  change the modules that are loaded.

* **Google Group**.  You will need a Google Group which contains all of your
  lab members (or, at least, the lab members who will be using this tool).  At
  Stanford, you should use [Workgroup
  Manager](https://uit.stanford.edu/service/workgroup) to create a workgroup,
  and map it to a Google Group.

* **Google Team Drive**.  You will need a Team Drive for your lab.  This is
  where all the data will live, and having it in a Team Drive will prevent the
  data from disappearing when someone leaves the lab.  Your Team Drive should
  be set up such that your Google Group has access to the Team Drive.

Once you have those prerequisites met, then you will be able to continue!

## rclone Setup

Once rclone is installed, it needs to be made aware of the Google Team Drive.
This is done by executing an rclone setup process.

**Each lab user will need to perform this step.**  The reason is, rclone needs
the lab user to authenticate with Google, so that rclone may perform actions on
the user's behalf.

The person in charge of this tool will need to choose a _remote name_, a
short identifier to represent the Google Team Drive.  _All lab members will
need to set up an rclone remote with this name_.

It works best if you can distribute a document or video walking people through
setting up the remote.  For example, the following asciinema is how members of
the Quake Lab learn how to set up rclone:

[![Set up a rclone remote for the Quake Lab Team Drive](https://asciinema.org/a/8uZIXFyKU707fiyAEsgQutWcE.svg)](https://asciinema.org/a/8uZIXFyKU707fiyAEsgQutWcE)

## Script Customization

Once rclone is set up, the tool needs to be customized to your environment.

**Take note** that this tool executes `rclone sync`, which will delete files
on Google Drive that are not present on the local filesystem.  So, this is _not
the same as a backup_!  The closest equivalent is to use `rclone copy`, which
does not delete remote files.

There are several lines in the tool which _must_ be changed:

```
#SBATCH --partition owners
```

This is where you set the SLURM partition where your jobs will run.  If
possible, you should choose a partition where resources are shared, and where
preemption is possible.

```shell
##SBATCH --error /dev/null
##SBATCH --output /dev/null
```

These two lines are disabled SLURM options.  To enable them, change `##` to
`#`.

When enabled, SLURM will stop creating a `.out` job output file for each job.
Ideally, the SLURM output files should be empty, and any problems are reported
to the user via email.  But, if something really fails, then this would be the
best way to find out.

For these settings, the suggested action is:

* Leave these two SLURM options disabled for now.

* Once people have been using this for a while, without errors, enable the two
  SLURM options.

* If people have problem in the future, re-disable them to collect more
  information.

```shell
remote_name=quakedrive
```

This is where you set the rclone remote name, which you chose during rclone
setup.

```shell
drive_path='Sherlock Backupss'
```

This is the path (in Google Drive) where files will be stored.  In the above
example, there is a "Sherlock Backupss" directory in the root of the Team
Drive.  Within that directory, the tool will create a directory with the user's
username, and within _that_ will be the actual files.

In other words, if you have the users 'a' and 'b', and each user is backing up
their "software" directory, the directory tree in Team Drive will look like
this:

```
Sherlock Backupss/
  a/
    software/
      ... files ...
  b/
    software/
      ... files ...
```

## Test!

Before you distribute the tool to users, test it yourself:  Run the script at
least once, and let it run a few days, to make sure that it is able to resubmit
itself.  It will help if you can run this on a directory with lots of files.

Once you are done testing, be sure to `scancel` the next day's sync jobs.

## Deploy!

To deploy this script, move it into a shared space for everyone to access.  You
do not want people making their own copies, else it will be difficult to push
out any updates.

Let people know that the script is available, and set policies on which
directories should be synced.

# Copyright, Licensing, and Support

This code is © 2018 The Board of Trustees of the Leland Stanford Junion
University, and is released under the [LICENSE](GNU General Public License,
Version 3).

This was created by the [Stanford Research Comptuing
Center](https://srcc.stanford.edu) for the [Quake
Lab](https://quakelab.stanford.edu), and is provided to the world in hopes that
it may be useful.  However, we do not have the resources available to provide
support for everyone who may wish to use it.
