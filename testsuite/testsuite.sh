#!/bin/bash -x

# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail

# http://stackoverflow.com/a/246128/586893
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# http://stackoverflow.com/a/192337/586893
SCRIPT_NAME="$(basename "$(test -L "$0" && readlink "$0" || echo "$0")")"

# http://stackoverflow.com/a/2173421/586893
trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

# http://unix.stackexchange.com/a/132524
PORT=$(python2.7 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')

# http://stackoverflow.com/a/8351489/586893
# Retries a command a configurable number of times with backoff.
#
# The retry count is given by ATTEMPTS (default 5), the initial backoff
# timeout is given by TIMEOUT in seconds (default 1.)
#
# Successive backoffs double the timeout.

function with_backoff {
  local max_attempts=${ATTEMPTS-3}
  local timeout=${TIMEOUT-1}
  local attempt=0
  local exit_code=0

  while (( $attempt < $max_attempts )) ; do
    set +e
    "$@"
    exit_code=$?
    set -e

    if [[ $exit_code == 0 ]]
    then
      break
    fi

    echo "Failure! Retrying in $timeout second..." 1>&2
    sleep $timeout
    attempt=$(( attempt + 1 ))
    timeout=$(( timeout * 2 ))
  done

  if [[ $exit_code != 0 ]]
  then
    echo "Could not run command '$@' after ${attempt} attempts" 1>&2
  fi

  return $exit_code
}

function success {
	local green=`tput setaf 2`
	local reset=`tput sgr0`
	echo "${green}$@${reset}"
	return 0
}

function fail {
	local red=`tput setaf 1`
	local reset=`tput sgr0`
	echo "${red}$@${reset}"
	return 1
}

make -C ${DIR} reinstall

SIMORGH_DB=":MEMORY:" ${DIR}/venv/bin/python2.7 ${DIR}/venv/bin/simorgh_server --port ${PORT} &

if [[ "$(with_backoff curl -I http://127.0.0.1:${PORT}/temperature_measurements |
         head -n 1 |
         cut -d$' ' -f2)" == 200 ]] ; then
	success "Established connection with simorgh_server on PORT ${PORT}"
else
	fail "FAILED to establish connection with simorgh_server on PORT ${PORT}"
	exit 1
fi

test ! -f ~/.simorgh_db.json

function random_uuid {
   uuidgen | tr '[:upper:]' '[:lower:]'
}

function mock_temperature_data {
    cat <<EOF
{
  "type": "temperature measurement",
  "id": "${1-$(random_uuid)}",
  "session": {
     "type": "session",
     "id": "$(random_uuid)",
     "timestamp": $(python2.7 -c 'import time; print(time.time())'),
     "process_name": "${SCRIPT_NAME}",
     "hostname": "${HOSTNAME}",
     "commit_id": "$(cd ${DIR} ; git rev-parse HEAD)"
  },
  "timestamp": $(python2.7 -c 'import time; print(time.time())'),
  "temperature": 21.0123,
  "device": {
     "type": "temperature measurement device",
     "id": "001A92053B6ABB4131340023",
     "manufacturer": "MCC",
     "model": "USB-TEMP"
  },
  "channel": 5
}
EOF
}

UUID1=$(random_uuid)
[[ "$(curl -i -H "Content-Type: application/json" \
      -X POST -d "$(mock_temperature_data ${UUID1})" \
      http://127.0.0.1:${PORT}/temperature_measurements | head -n 1 | cut -d$' ' -f2)" == "200" ]] || exit 1

[[ $(curl http://127.0.0.1:${PORT}/temperature_measurements | python -m json.tool) =~ ${UUID1} ]] || exit 1

UUID2=$(random_uuid)
[[ "$(curl -i -H "Content-Type: application/json" \
      -X PUT -d "$(mock_temperature_data ${UUID2})" \
      http://127.0.0.1:${PORT}/temperature_measurements | head -n 1 | cut -d$' ' -f2)" == "200" ]] || exit 1

[[ $(curl http://127.0.0.1:${PORT}/temperature_measurements | python -m json.tool) =~ ${UUID1} ]] || exit 1
[[ $(curl http://127.0.0.1:${PORT}/temperature_measurements | python -m json.tool) =~ ${UUID2} ]] || exit 1

echo "--------------------- ☺︎ SUCCESS! ☺︎ ---------------------"