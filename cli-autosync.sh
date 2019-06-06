#!/bin/bash


# Annahmen:
#- speicherziel muss bereits gemountet sein (mit den richtigen Berechtigungen)
#- seafile-user mit eingeschränkten Rechten muss angelegt sein
#- ich nehme nur read-write Freigaben  an...
#- seaf-cli und seafile-gui können nicht parallel installiert werden.
#- wenn webdav, dann sollte richtig konfiguriert werden...


# welche fälle gibt es:
#- storage ziel ist weg > seaf-daemon stoppt
#- bibliothek wird gelöscht oder berechtigung entfernt > desync dieser bibliothek
#- seafile ist weg > seaf-daemon stoppt
#- seaf-cli antwortet nicht > konnte ich nicht reproduzieren
# wie merke ich, dass der seaf-cli zwar als process da ist, aber einen fehler zurückmeldet?

# wie mounte ich hidrive: (nur ssl + webdav)
#https://webdav.hidrive.strato.com/users/share-3452/ /mnt/hidrive davfs rw,gid=1000,uid=1000,_netdev 0 0

#/etc/davfs2/secrets
#/mnt/hidrive share-3452 e6n;uVku

#/etc/davfs2/davfs2.conf
#use_locks 0
#cache_size 1
#table_size 4096
#gui_optimize 1
#trust_server_cert  /etc/davfs2/certs/hidrive.pem
#buf_size 1024
#if_match_bug 0
#max_upload_attempts 5
#dir_refresh 600
#file_refresh 5
#debug config
#debug kernel
#debug cache
#debug http
#debug xml
#debug httpauth
#debug locks
#debug ssl
#debug httpbody
#debug secrets
#debug most

# https://neu.lu/2017/03/webdav-mount-im-dateisystem/
#echo|openssl s_client -connect webdav.hidrive.strato.com:443 |openssl x509 -out /etc/davfs2/certs/hidrive.pem

# Erläuterungen: warum ich rein "read-only" mache: 
#- einfach auf strato eine datei hinzufügen und dann wieder löschen. schon ist wait for sync...
#[06/04/19 14:45:32] sync-mgr.c(559): Repo 'Bibliothek-A' sync state transition from 'synchronized' to 'uploading'.
#[06/04/19 14:45:32] http-tx-mgr.c(1181): Transfer repo '9d950701': ('normal', 'init') --> ('normal', 'check')
#[06/04/19 14:45:32] http-tx-mgr.c(2438): Bad response code for GET https://seafile-demo.de/seafhttp/repo/9d950701-5c67-4e7a-8d54-94fc7c802542/permission-check/?op=upload&client_id=9ca3b20e583b0869ff2ed854d4dbeac81f90b1c1&client_name=unknown: 403.
#[06/04/19 14:45:32] http-tx-mgr.c(3708): Upload permission denied for repo 9d950701 on server https://seafile-demo.de.
#[06/04/19 14:45:32] http-tx-mgr.c(1181): Transfer repo '9d950701': ('normal', 'check') --> ('error', 'finished')
#=> waiting for sync...
#=> ich muss read-write zugriff geben...

#- wenn ich read-write mache, dann muss man bei änderungen auf hidrive den seaf-cli stoppen und starten.
# er erkennt keine änderungen auf hidrive...

# sync-intervall pro repo ist notwendig => geht, aber muss ich manuell einfügen...

#---- wenn ich strato unmounte, sind alle syncs weg...
# wenn ich strato wieder hole und ein ... run mache, sind wieder alle da...
# also muss ich die richtige anzeige machen bzw. prüfen, ob das ziel da ist...

#---- wenn ich eine biblitoehk auf dem server entferne...
# verschwindet nicht auf cli-client...
# ich muss ein desync machen...


## alle Werte bitte ohne "/" am Ende ...
server="https://192.168.5.241"
user="seaf-cli@tomatenblau.de"
pw="Ionas12345"
syncto="/mnt/hidrive/nuc"
logfile="/home/datamate/seafcli-status.html"
syncintervall=60

## --------------------------
## AB HIER NICHTS MEHR ÄNDERN
## --------------------------

export PYTHONHTTPSVERIFY=0
export PYTHONIOENCODING=UTF-8

# check that only ONE seaf-cli is running
function start(){
  if [ -e ~/.ccnet/ ]; then
    NUM=`pgrep seaf-daemon | wc -l`
    if [[ ${NUM} == 0 ]]; then
      echo "Der seaf-daemon wird gestartet."
      seaf-cli start
    elif [[ ${NUM} > 1 ]]; then
      echo "zu viele seaf-daemons wurden gefunden. Ich beende alle und starte seaf-daemon neu ..."
      seaf-cli stop
      sleep 1
      killall -9 seaf-daemon
      seaf-cli start
    fi
  fi
}

function stop(){
  echo "Der seaf-daemon wird gestoppt."
  seaf-cli stop
  sleep 2
  killall -9 seaf-daemon > /dev/null 2>&1
}

# check that seafile is running
ping=`curl -s ${server}/api2/ping/ --insecure`           # vielleicht das --insecure wieder raus...
if [[ $ping != '"pong"' ]]; then
  echo "Seafile scheint nicht zu laufen. Ich beende den seaf-daemon ..."
  echo "Seafile scheint nicht zu laufen. Ich beende den seaf-daemon ..." > $logfile
  stop
  exit 1
fi

# check that storage is available
if [ ! -e ${syncto}/seafcli-ready ]; then
  echo "Der Zielspeicher scheint nicht gemountet zu sein. Ich beende den seaf-daemon ..."
  echo "Der Zielspeicher scheint nicht gemountet zu sein. Ich beende den seaf-daemon ..." > $logfile
  stop
  exit 1
fi


if [[ $1 == "init" ]]; then

  if [ -e ~/.ccnet ]; then
    echo "'$0 init' wurde anscheinend schon ausgeführt, da das Verzeichnis .ccnet schon existiert. Abbruch ..."
    echo "'$0 init' wurde anscheinend schon ausgeführt, da das Verzeichnis .ccnet schon existiert. Abbruch ..." > $logfile
    exit 1
  fi

  # init (muss nur einmal ausgeführt werden...)
  sudo add-apt-repository ppa:seafile/seafile-client -y
  sudo apt-get update
  sudo apt-get install -y curl nano jq seafile-cli davfs2

  seaf-cli init -d ~/.ccnet
  seaf-cli start

  echo "Diese Datei bitte nicht löschen. 
  Sie muss vorhanden sein, damit die Synchronisation läuft..." > ${syncto}/seafcli-ready

  # um Sync-Abbrüche zu verhindern (brauche ich nicht mehr...)
  #seaf-cli config -k allow_invalid_worktree -v true
  #seaf-cli config -k allow_repo_not_found_on_server -v true

  # wenn kein gültiges SSL-Zertifikat, dann muss dieser Wert gesetzt sein um eine funktionierende Synchronisation hinzukriegen
  sleep 2
  seaf-cli config -k disable_verify_certificate -v true

  # add cronjob
  path=`realpath "$0"`
  CRON="*/30 * * * * $cronjob_schedule ${path} run > /dev/null 2>&1"
  crontab -l | grep -v $path | crontab -
  crontab -l > mycron.tmp
  echo "$CRON" >> mycron.tmp
  crontab mycron.tmp
  rm mycron.tmp

  # stop client (muss ich aber am Ende gar nicht machen...)
  # seaf-cli stop


elif [[ $1 == "start" ]]; then
  start


elif [[ $1 == "stop" ]]; then
  stop


elif [[ $1 == "run" ]]; then
  start

  if [ ! -e ~/.ccnet/seafile.ini ] || [ ! -e ~/.ccnet/seafile-data/repo.db ]; then
    echo "Dieses Script wurde entweder mit dem falschen Benutzer gestartet oder es wurde noch kein '$0 init' ausgeführt. Abbruch ..."
    echo "Dieses Script wurde entweder mit dem falschen Benutzer gestartet oder es wurde noch kein '$0 init' ausgeführt. Abbruch ..." > $logfile
    exit 1
  fi

  restart=0

  # schreibe die lokalen Librarys in eine Liste. 
  # Entferne die librarys, die auch remote gefunden werden
  # die übrig gebliebenen müssen desynct werden...
  CUR_LIST=`/usr/bin/seaf-cli list` 
  echo "${CUR_LIST}" > /tmp/seafcli-list.tmp 
  sed -i 1d /tmp/seafcli-list.tmp

  # get seafile-token
  token=`curl -s --data-urlencode username=${user} -d password=${pw} ${server}/api2/auth-token/ --insecure | jq -r '.token'`
  
  if [[ ${#token} -lt 10 ]]; then
    echo "Die Seafile Zugangsdaten stimmen nicht. Ich beende den seaf-daemon ..."
    echo "Die Seafile Zugangsdaten stimmen nicht. Ich beende den seaf-daemon ..." > $logfile
    stop
    exit 1
  fi

  # get the library-ids
  lib_ids=`seaf-cli list-remote -s "${server}" -u "${user}" -p "${pw}" | awk '{print $NF}'`
  for id in $lib_ids; do
    if [ $id != "ID" ]; then

      # only sync library if it is read-only
      perm=`curl -s -H "Authorization: Token ${token}" -H 'Accept: application/json; indent=4' "${server}/api2/repos/${id}/" --insecure | jq -r '.permission'`
      name=`curl -s -H "Authorization: Token ${token}" -H 'Accept: application/json; indent=4' "${server}/api2/repos/${id}/" --insecure | jq -r '.name'`

      if [ ${perm} == "rw" ]; then
        echo "...${name}..."
        mkdir -p "${syncto}/${name}"
        sed -i "/${id}/d" /tmp/seafcli-list.tmp
        python -u /usr/bin/seaf-cli sync -l "$id" -d "${syncto}/${name}" -s "${server}" -u "${user}" -p "${pw}" > /dev/null 2>&1
        
        if [[ $? == 0 ]]; then
          echo "Starting to download..."
          sqlite3 ~/.ccnet/seafile-data/repo.db "INSERT INTO RepoProperty (repo_id, key, value) VALUES ('"${id}"', 'sync-interval', '"${syncintervall}"');"
          restart=1
        fi

      fi

    fi
  done

  # entferne die übrig gebliebenen IDs aus /tmp/seafcli-list.tmp
  cat /tmp/seafcli-list.tmp | while read line
  do
    syncpath="/"`echo "$line" | cut -d'/' -f2-`
    seaf-cli desync -d "$syncpath"
  done

  # write output to file
  CUR_STATUS=`/usr/bin/seaf-cli status`
  echo "<h3>Status vom `date +%d.%m.%Y` - `date +%T`</h3><pre>${CUR_STATUS}</pre>" > $logfile


  if [[ ${restart} == 1 ]]; then
    echo "Es ist eine neue Synchronisation hinzugekommen. Der seaf-daemon muss neu gestartet werden..."
    stop
    start
  fi


elif [[ $1 == "status" ]]; then
  start
  sleep 1
  seaf-cli status


else
  echo "
Description: Command tool for the seafile command line client. Share a library or a folder to the
             seafile user defined in this file and will automatically synced.
Usage:       cli-autosync.sh [option]
Options:
  init       Initalization of this script. Installs packages, cronjobs and init seaf-cli client
  start      Starts the seaf-cli client. Makes sure that only one process is running
  stop       Stops the seaf-cli client. Makes sure that all processes are terminated
  run        Automounts libraries or folders that are shared to the user
  status     Shows the current sync status
"

fi

