# cli-autosync (or Seafile High Availability Lite)

This shell script synchronizes Seafile files and folders to external storage. While the files are stored block-based in Seafile, the files are stored in the external memory in the file format. Changes to the files and folder structure can be made on both sides. This script uses the Seafile-CLI (command line interface of the seafile client).

Once the script is set up, its use is easy. All you have to do is to share a folder or a library with a special Seafile user to include it in the synchronization.

<img src="https://de.seafile.com/wp-content/uploads/2019/06/Replikation_Seafile_CLI-_Client.png" />


# Prerequisites

This script was tested with seafile 6.3.x (CE and PE). To use this solution, the following points are mandatory:

- the external storage has to be mounted on the seafile-server (e.g. a Strato HiDrive via WebDAV or another storage via nfs)
- the linux system user that will execute this script has to have write access to this mounted storage.
- a dedicated Seafile user should be created
- (Optional) create a dedicated seafile user role with only the permission *can_connect_with_desktop_clients = true*

# Installation

As soon as the preparation is done, the installation is quite easy:

- Download this script *cli-autosync.sh* from Github
- make this script executable ```chmod +x cli-autosync.sh```
- change the settings at the top of *cli-autosync.sh*
- initialise with ```./cli-autosync.sh init```

This call makes the following changes to the system:

- The package seaf-cli is installed.
- It checks if the Seafile server is reachable.
- A file will be created on the external memory to check in the future whether the external memory is also mounted reliably.
- The seaf-cli is configured to handle self-generated server HTTPS certificates.
- A cron job is created, which regularly checks for newly added releases and automatically includes them in the synchronization.

# Usage of this script

Once the installation is complete, it is sufficient to release a library or folder to the Seafile user specified in the script. The releases must be done "read + write", otherwise the synchronization will not be established.

Of course, the sync is also stopped again, if you remove the release sometime. The previously synchronized data remains on the external memory and will not be deleted.

If you have granted a release, you can either wait until the next execution of the cronjob or manually check for existing shares:

```
./cli-autosync.sh run
# This call is called regularly via cronjob

./cli-autosync.sh status
# this indicates the current status of the synchronization
```

## Appendix 1: Mount of Strato HiDrive via WebDAV
This solution was tested with HiDrive from the German supplier Strato. This external storage can be mounted via WebDAV in the Seafile server.

The following optimizations were made.

```
# Install davfs2 and add the hidrive credentials
$ sudo su
$ apt-get install davfs2
$ echo "/mnt/hidrive <HIDRIVE-USER> <HIDRIVE-PASSWORD>" >> /etc/davfs2/secrets

# Append the following options to /etc/davfs2/davfs2.conf
cache_size 1
table_size 4096
gui_optimize 1
trust_server_cert  /etc/davfs2/certs/hidrive.pem
buf_size 1024
if_match_bug 0
max_upload_attempts 5
dir_refresh 600
file_refresh 5

# Import the SSL-Certificate of Strato HiDrive (necessary for an encrypted webdav connection)
$ echo|openssl s_client -connect webdav.hidrive.strato.com:443 |openssl x509 -out /etc/davfs2/certs/hidrive.pem

# Add the following to the /etc/fstab to mount hidrive after reboot
# get the uid with id -u username
https://webdav.hidrive.strato.com/users/<HIDRIVE-USER>/ /mnt/hidrive davfs rw,gid=1000,uid=1000,_netdev 0 0
```

## Appendix 2: Why are only "read+write" shares supported?

Unfortunately a read-only share can make some problems. If there is a file change on the external storage the seafile-cli tries to sync these changes back to seafile. The seafile-cli askes for the permission to write it back and receives an error 403. After that the seafile-cli client is stuck in the status "waiting for sync". 
```
# this is how the log looks like...
[06/04/19 14:45:32] sync-mgr.c(559): Repo 'Bibliothek-A' sync state transition from 'synchronized' to 'uploading'.
[06/04/19 14:45:32] http-tx-mgr.c(1181): Transfer repo '9d950701': ('normal', 'init') --> ('normal', 'check')
[06/04/19 14:45:32] http-tx-mgr.c(2438): Bad response code for GET https://seafile-demo.de/seafhttp/repo/9d950701-5c67-4e7a-8d54-94fc7c802542/permission-check/?op=upload&client_id=9ca3b20e583b0869ff2ed854d4dbeac81f90b1c1&client_name=unknown: 403.
[06/04/19 14:45:32] http-tx-mgr.c(3708): Upload permission denied for repo 9d950701 on server https://seafile-demo.de.
[06/04/19 14:45:32] http-tx-mgr.c(1181): Transfer repo '9d950701': ('normal', 'check') --> ('error', 'finished')
```
I am quite sure that this is not the desired behaviour. I already created a ticket at the seafile forum.
<a href="https://forum.seafile.com/t/seaf-cli-does-sticks-at-waiting-for-sync/9066">https://forum.seafile.com/t/seaf-cli-does-sticks-at-waiting-for-sync/9066</a>

