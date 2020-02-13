#!/bin/bash

# Forked from: https://github.com/datamate-rethink-it/cli-autosync

# Changelog (https://github.com/labor4)
# - begin external vars file
# - add user PATH to cron, probably good
# - more ifs and buts upon got-work-to-do
# - renaming more $vars into ${VARS}
# - adding a helper info "latestlibgrab" with date for debugging/checking  
# - begin a bindfs strategy (Originals at ${ORIGINALS}/${NAME} will be mounted to ${SEAFMOUNTPOINTS}/${NAME}
# - begin a readonly strategy
# - begin manifest.txt communication
# - begin sidecar file (a ${NAME}.info file with settings). loc is probably gonna change.
# - indents, cleanup
# - dirty reordering fix of "seafcli-ready"
# - TORETHINK: bindfs is good to bodge weird situations, but is expensive and slow compared to a symlink on same fs.
# - logthis(), >>, ${LOGFILE}.txt, ${LOGFILE}.html
# - begin handling ID conflict, not finished, maybe settings-file loc needs to be centralized first.
# - adding owner whitelist and API-fail workaround (for-loop). Suited as a Backup Server. 
# - adding FORCEREADONLIES and FORCEREADWRITES

# Extended Concept since the Original:
# We needed a way to be independent from Seafile features/bugs/needs to a certain degree.
# As we used SF as a exchange method to hook partners into an otherwise isolated project server, 
# we went for a route to use bindfs to be open for future special needs, not knowing what they are.
# Thus, SF syncs to bindfs mounts instead of real directories.
# The manifest.txt is another idea of the former, to instantly communicate internal advice back to the partners.
# The following is an adaption of that project into a semi-open backup server, 
# adding a mask to "who can trigger an auto-backup" via an owner restriction (whitelist),
# plus a means to prevent accidental replacement of a previous sync by identical REPO name.

# work in progress

source $HOME/myseafconf/vars.env


## alle Werte bitte ohne "/" am Ende ...
# From vars.env // temp naming
SERVER="$MYSEAFSERVER"
USER="$MYSEAFUSER"
PW="$MYSEAFPASS"
SEAFPARENT=$MYSTORAGEPARENT
SEAFMOUNTPOINTS="$SEAFPARENT/seafile"
SEAFDATADIR="$SEAFPARENT/seafile-data"
ORIGINALS="$MYORIGSYNCDIR"
MANIFEST="${ORIGINALS}/manifest.ORIG.txt"

LOGFILE="$HOME/myseafconf/seafcli-status"
WHITEFILE="$HOME/myseafconf/white.list"


MYINSECURITY="--insecure" # last christmas, i gave you my heart, but the very next day...
MYINSECURITY=""

HANDLERENAMECONFLICT=0
USEWHITEFILE=1
FORCEREADONLIES=1
FORCEREADWRITES=0
SYNCINTERVAL=60

sfCLI="/usr/bin/seaf-cli"
## --------------------------
## AB HIER NICHTS MEHR ÄNDERN
## --------------------------


mkdir -p "$SEAFPARENT" "${ORIGINALS}"
mkdir -p "${ORIGINALS}"

touch "${WHITEFILE}"
touch "${MANIFEST}"

export PYTHONHTTPSVERIFY=0
export PYTHONIOENCODING=UTF-8

# check that only ONE ${sfCLI} is running
function start(){
    if [ -e ~/.ccnet/ ]; then
        NUM=$(pgrep seaf-daemon | wc -l)
        if [[ ${NUM} == 0 ]]; then
            echo "Der seaf-daemon wird gestartet."
            ${sfCLI} start
        elif [[ ${NUM} > 1 ]]; then
            echo "zu viele seaf-daemons wurden gefunden. Ich beende alle und starte seaf-daemon neu ..."
            ${sfCLI} stop
            sleep 1
            killall -9 seaf-daemon
            ${sfCLI} start
        fi
    fi
}

function logthis(){
    echo "$1"
    echo "$(date '+%F %T'): $1" >> ${LOGFILE}.txt
}

function stop(){
    echo "Der seaf-daemon wird gestoppt."
    ${sfCLI} stop
    sleep 2
    killall -9 seaf-daemon > /dev/null 2>&1
}

function editsettings(){
    local OPTIND c k v f
    while getopts 'k:v:f:' c
    do
      case $c in
        k) mKEY="$OPTARG" ;;
        v) mVAR="$OPTARG" ;;
        f) mCONFIG_FILE="$OPTARG" ;;
      esac
    done
    if [ -f "$mCONFIG_FILE" ] && egrep -q "^$mKEY=" "$mCONFIG_FILE"
    then
        sed -i -e "/^$mKEY=/s/=.*/=$mVAR/" "$mCONFIG_FILE"
        #echo found $mKEY=
    else
        echo $mKEY=$mVAR >> "$mCONFIG_FILE"
        #echo not found $mKEY=
    fi
    shift $((OPTIND-1))

    sort -o "$mCONFIG_FILE" "$mCONFIG_FILE"
    
}

function getsettings(){
    local OPTIND c k f
    while getopts 'k:f:' c
    do
      case $c in
        k) mKEY="$OPTARG" ;;
        f) mCONFIG_FILE="$OPTARG" ;;
      esac
    done
    if [ -f "$mCONFIG_FILE" ] && egrep -q "^$mKEY=" "$mCONFIG_FILE"
    then
        sed -ne "s/^$mKEY=\(.*\).*/\1/p" "$mCONFIG_FILE"
        #echo found $mKEY=
    else
        echo
        #echo not found $mKEY=
    fi
    shift $((OPTIND-1))
}

function getownerforID(){
    # ${SERVER}/api2/repos/${ID}/owner/ is broken, even as an Admin (7.0.4).
    # This is a for-loop-until-found
    
    tmpTOKEN="$1"
    tmpID="$2"
    tmpDUMP=$(curl -s -H "Authorization: Token ${tmpTOKEN}" -H 'Accept: application/json; indent=4' "${SERVER}/api2/repos/" ${MYINSECURITY})
    for row in $(echo "${tmpDUMP}" | jq -r '.[] | @base64'); do
        _jq() {
         echo ${row} | base64 --decode | jq -r ${1}
        }

        if [[ $(_jq '.id') == "${tmpID}" ]];then
            echo $(_jq '.owner')
            break
        fi
    done
}



# check that seafile is running
ping=$(curl -s ${SERVER}/api2/ping/ ${MYINSECURITY})           # vielleicht das ${MYINSECURITY} wieder raus...
if [[ $ping != '"pong"' ]]; then
    logthis "Seafile scheint nicht zu laufen. Ich beende den seaf-daemon ..."
    stop
    exit 1
fi


if [[ $1 == "init" ]]; then

    if [ -e ~/.ccnet ]; then
        logthis "'$0 init' wurde anscheinend schon ausgeführt, da das Verzeichnis .ccnet schon existiert. Abbruch ..."
        exit 1
    fi

    # init (muss nur einmal ausgeführt werden...)
    sudo add-apt-repository ppa:seafile/seafile-client -y
    sudo apt-get update
    sudo apt-get install -y curl nano jq seafile-cli davfs2 sqlite3 bindfs

    ${sfCLI} init -d "$SEAFPARENT"
    ${sfCLI} start

    echo "Diese Datei bitte nicht löschen. 
Sie muss vorhanden sein, damit die Synchronisation läuft..." > ${SEAFMOUNTPOINTS}/seafcli-ready

    # um Sync-Abbrüche zu verhindern (brauche ich nicht mehr...)
    #${sfCLI} config -k allow_invalid_worktree -v true
    #${sfCLI} config -k allow_repo_not_found_on_server -v true

    # wenn kein gültiges SSL-Zertifikat, dann muss dieser Wert gesetzt sein um eine funktionierende Synchronisation hinzukriegen
    sleep 2
    if [[ "${MYINSECURITY}" != "" ]];then
        ${sfCLI} config -k disable_verify_certificate -v true
    fi
    
    # add cronjob
    # FIXME: $cronjob_schedule?
    
    myPATH=$(realpath "$0")
    CRON="*/30 * * * * $cronjob_schedule ${myPATH} run > /dev/null 2>&1"
    crontab -l | grep -v $myPATH | crontab -
    crontab -l > mycron.tmp
    echo "PATH=$PATH" >> mycron.tmp
    echo "$CRON" >> mycron.tmp
    crontab mycron.tmp
    rm mycron.tmp

    # stop client (muss ich aber am Ende gar nicht machen...)
    # ${sfCLI} stop


elif [[ $1 == "stop" ]]; then
    stop


elif [ ! -e ${SEAFMOUNTPOINTS}/seafcli-ready ]; then
    # check that storage is available
    logthis "Der Zielspeicher scheint nicht gemountet zu sein. Ich beende den seaf-daemon ..."
    stop
    exit 1


elif [[ $1 == "start" ]]; then
    start


elif [[ $1 == "run" ]]; then
    start

    if [ ! -e ~/.ccnet/seafile.ini ] || [ ! -e $SEAFDATADIR/repo.db ]; then
        logthis "Dieses Script wurde entweder mit dem falschen Benutzer gestartet oder es wurde noch kein '$0 init' ausgeführt. Abbruch ..."
        exit 1
    fi

    RESTART=0
    # Concept:
    # schreibe die lokalen Librarys in eine Liste. 
    # Entferne die librarys, die auch remote gefunden werden
    # die übrig gebliebenen müssen desynct werden...
    CUR_LIST=$(${sfCLI} list)
    echo "${CUR_LIST}" > /tmp/seafcli-list.tmp 
    echo "${CUR_LIST}" > /tmp/seafcli-list-view.tmp 
    sed -i 1d /tmp/seafcli-list.tmp

    # get seafile-token
    TOKEN=$(curl -s --data-urlencode username=${USER} -d password=${PW} ${SERVER}/api2/auth-token/ ${MYINSECURITY} | jq -r '.token')

    if [[ ${#TOKEN} -lt 10 ]]; then
        logthis "Die Seafile Zugangsdaten stimmen nicht. Ich beende den seaf-daemon ..."
        stop
        exit 1
    fi

    # get the library-ids
    LIB_IDS=$(${sfCLI} list-remote -s "${SERVER}" -u "${USER}" -p "${PW}" | awk '{print $NF}')
    
    for ID in ${LIB_IDS}; do
        
        if [ ${ID} != "ID" ]; then
        
            HASIDCONFLICT=0

            DUMP=$(curl -s -H "Authorization: Token ${TOKEN}" -H 'Accept: application/json; indent=4' "${SERVER}/api2/repos/${ID}/" ${MYINSECURITY})
            
            PERM=$(echo  "${DUMP}"  | jq -r '.permission')
            NAME=$(echo  "${DUMP}"  | jq -r '.name')

            logthis "
Looking at REPO ${ID} with remote name '${NAME}'"
            
            if [ ${USEWHITEFILE} -eq 1 ];then
                
                logthis "Whitelisting is 'active', gonna filter this."
                OWNER=$(getownerforID "${TOKEN}" "${ID}")
                
                if [[ "${OWNER}" != "" ]] && egrep -q "^${OWNER}$" "${WHITEFILE}"; then
                    logthis "Owner: '${OWNER}' IS whitelisted. Continuing."

                else
                    logthis "Owner: '${OWNER}' is NOT whitelisted. Skipping REPO."
                    continue
                    
                fi

            fi
            
            # checking authenticity/ samename conflict
            if [ -f "${ORIGINALS}/${NAME}.info" ];then
                
                FOUNDID=$(getsettings -k id -f "${ORIGINALS}/${NAME}.info")
                logthis "Found pre-existing '${FOUNDID}' at location '${ORIGINALS}/${NAME}'"
                
                if [ "${ID}" != "$FOUNDID" ];then
                    logthis "${FOUNDID} DOES NOT MATCH THE LOCAL REPO!!"
                    logthis "Quickfix: Move '${NAME}' and '${NAME}.info' somewhere else."
                    HASIDCONFLICT=1
                else
                    logthis "... and it matches the remote repo. Sync is OK. Continuing."
                fi
                
            fi
            
            if [ ${HASIDCONFLICT} -eq 1 ];then
                
                if [ ${HANDLERENAMECONFLICT} -eq 1 ];then
                    tmpSUFFIX=$(echo "${ID}" | awk -F"-" '{print $NF}')
                    newname=${NAME}_${tmpSUFFIX}
                    echo $newname
                    continue
                    #TODO
                else
                    # skip this REPO
                    logthis "Not gonna fix this myself. PREVENTING OVERWRITE. Skipping '${NAME}'."
                    continue
                fi
                
            fi
            
            # Forcing either rw or r
            if [ ${PERM} == "rw" ] && [ ${FORCEREADONLIES} -eq 1 ];then
                logthis "Error. FORCEREADONLIES=1 is set, but permissions are '${PERM}'. Aborting."
                continue
                
            elif [ ${PERM} == "r" ] && [ ${FORCEREADWRITES} -eq 1 ];then
                logthis "Error. FORCEREADWRITES=1 is set, but permissions are '${PERM}'. Aborting."
                continue
                
            # you never know...
            elif [ ${PERM} == "rw" ] || [ ${PERM} == "r" ];then
                
                logthis "REPO '${NAME}' has perms: '${PERM}' and is eligible to sync. Continuing."
                if [[ -d "${SEAFMOUNTPOINTS}/${NAME}" ]] && [[ -d "${ORIGINALS}/${NAME}" ]] &&  mount | grep "${SEAFMOUNTPOINTS}/${NAME}" > /dev/null ;then
                    sed -i "/${ID}/d" /tmp/seafcli-list.tmp

                    editsettings -k "ismaybeunsynced" -v "" -f "${ORIGINALS}/${NAME}.info"
                    editsettings -k "latestlibgrab" -v "$(date)" -f "${ORIGINALS}/${NAME}.info"

                    python -u ${sfCLI} sync -l "${ID}" -d "${SEAFMOUNTPOINTS}/${NAME}" -s "${SERVER}" -u "${USER}" -p "${PW}" > /dev/null 2>&1
                    
                    logthis "Modifying Interval..."
                    sqlite3 $SEAFDATADIR/repo.db "INSERT OR REPLACE INTO RepoProperty ('repo_id', 'key', 'value') 
SELECT '"${ID}"', 'sync-interval', '"${SYNCINTERVAL}"'
WHERE NOT EXISTS (SELECT * FROM RepoProperty WHERE repo_id = '"${ID}"' AND key = 'sync-interval');
UPDATE RepoProperty SET value='"${SYNCINTERVAL}"' WHERE repo_id='"${ID}"' AND key='sync-interval';
"

                    # writing info to sidecar
                    editsettings -k id -v ${ID} -f "${ORIGINALS}/${NAME}.info"
                    
                else 
            
                    if [[ -d "${SEAFMOUNTPOINTS}/${NAME}" ]];then
                        logthis "Info. ${SEAFMOUNTPOINTS}/${NAME} Exists!"
                    fi
                    if [[ -d "${ORIGINALS}/${NAME}" ]];then
                        logthis "Info. ${ORIGINALS}/${NAME} Exists!"
                    fi
                    mkdir -p "${SEAFMOUNTPOINTS}/${NAME}"
                    mkdir -p "${ORIGINALS}/${NAME}"
            
                    if [[ ! -f "${ORIGINALS}/${NAME}/manifest.txt" ]] && [ ${PERM} == "rw" ];then
                        cp  "${MANIFEST}" "${ORIGINALS}/${NAME}/manifest.txt"
                    fi
                    
                    # mounting the dir into the seafile target
                    bindfs -p u=rwx,g=rwx "${ORIGINALS}/${NAME}" "${SEAFMOUNTPOINTS}/${NAME}" 
                    if [[ "$?" -ne 0 ]];then
                        logthis "Error with bindfs mount! Skipping REPO."
                        continue
                    fi
                    editsettings -k "ismaybeunsynced" -v "" -f "${ORIGINALS}/${NAME}.info"
                    editsettings -k "latestlibgrab" -v "$(date)" -f "${ORIGINALS}/${NAME}.info"
            
                    python -u ${sfCLI} sync -l "${ID}" -d "${SEAFMOUNTPOINTS}/${NAME}" -s "${SERVER}" -u "${USER}" -p "${PW}" > /dev/null 2>&1
                    logthis "Modifying Interval..."
                    sqlite3 $SEAFDATADIR/repo.db "INSERT OR REPLACE INTO RepoProperty ('repo_id', 'key', 'value') 
SELECT '"${ID}"', 'sync-interval', '"${SYNCINTERVAL}"'
WHERE NOT EXISTS (SELECT * FROM RepoProperty WHERE repo_id = '"${ID}"' AND key = 'sync-interval');
UPDATE RepoProperty SET value='"${SYNCINTERVAL}"' WHERE repo_id='"${ID}"' AND key='sync-interval';
"
                    
                    # writing info to sidecar
                    editsettings -k id -v ${ID} -f "${ORIGINALS}/${NAME}.info"
                    
                fi # -d dirs exist

            fi #perm

        fi #ID
    done

    # entferne die übrig gebliebenen IDs aus /tmp/seafcli-list.tmp
    cat /tmp/seafcli-list.tmp | while read line
    do
        tmpSYNCPATH="/"$(echo "${line}" | cut -d'/' -f2-)
        echo "Desync ${tmpSYNCPATH}"
        ${sfCLI} desync -d "${tmpSYNCPATH}"
        echo "Fuser Umount ${tmpSYNCPATH}"
        fusermount -u "${tmpSYNCPATH}"
        rmdir "${tmpSYNCPATH}"
    done

    # write output to file
    CUR_STATUS=$(${sfCLI} status)
    echo "<!DOCTYPE html><html lang='de'><head><title>Seafcli-status</title><meta charset='utf-8'/></head><body>
<h3>Status vom $(date +%d.%m.%Y) - $(date +%T)</h3><pre>${CUR_STATUS}</pre>
</body></html>
" > ${LOGFILE}.html


    if [[ ${RESTART} == 1 ]]; then
        echo "Es ist eine neue Synchronisation hinzugekommen. Der seaf-daemon muss neu gestartet werden..."
        stop
        start
    fi


elif [[ $1 == "status" ]]; then
    start
    sleep 1
    ${sfCLI} status


else
    echo "
Description: Command tool for the seafile command line client. Share a library or a folder to the
         seafile user defined in this file and will automatically synced.
Usage:       cli-autosync.sh [option]
Options:
init       Initalization of this script. Installs packages, cronjobs and init ${sfCLI} client
start      Starts the ${sfCLI} client. Makes sure that only one process is running
stop       Stops the ${sfCLI} client. Makes sure that all processes are terminated
run        Automounts libraries or folders that are shared to the user
status     Shows the current sync status
"

fi

