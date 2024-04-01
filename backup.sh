#!/bin/bash

AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
REPO_NAME="bck-example"
REPO_PWFILE="/root/.restic"
REPO_URL="s3:s3.eu-central-003.backblazeb2.com/$REPO_NAME"
BACKUP_FILE_LIST="./backups.txt"
EXCLUDE_FILE_LIST="./exclude.txt"
RECIPIENT_EMAIL="jannis@jnns.de"
SMTP_SERVER="mail.jnns.de:465"
SMTP_USERNAME="i@example.com"
SMTP_PASSWORD=""

check_file_exists() {
  [[ -f "$1" ]] || { echo "Error: File $1 not found. Exiting."; exit 1; }
}

check_command_installed() {
  local command_name="$1"
  if ! command -v "$command_name" &> /dev/null; then
    echo "$command_name is not installed. Installing..."
    apt install -y $command_name
  fi
}

run_restic() {
  local output
  output=$(restic -p "$REPO_PWFILE" -r "$REPO_URL" "$@" 2>&1) || { echo "Error: $output"; return 1; }
  echo "$output"
}

urlencode() {
  local string="$1"
  local encoded_string=""
  local char

  for ((i = 0; i < ${#string}; i++)); do
    char="${string:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        encoded_string+="$char"
        ;;
      *)
        printf -v encoded_char '%%%02x' "'$char"
        encoded_string+="$encoded_char"
        ;;
    esac
  done

  printf "%s" "$encoded_string"
}

send_email() {
  local hostname=$(hostname)
  local subject="Backup Failure on \"$hostname\""
  local body="Backup process failed on $hostname:\n\n$output"

  echo -e "$body" | s-nail -s "$subject" \
    -S v15-compat \
    -S mta=smtps://"$(urlencode $SMTP_USERNAME)":"$SMTP_PASSWORD"@"$SMTP_SERVER" \
    -S from="$SMTP_USERNAME" \
    "$RECIPIENT_EMAIL"
}

check_command_installed "s-nail"
check_command_installed "restic"

check_file_exists "$REPO_PWFILE"
check_file_exists "$BACKUP_FILE_LIST"

if [ -f "$EXCLUDE_FILE_LIST" ]; then
  echo "Using exclude file: $EXCLUDE_FILE_LIST"
  EXCLUDE_OPTION="--exclude-file $EXCLUDE_FILE_LIST"
else
  echo "No exclude file found. Proceeding without exclusions."
  EXCLUDE_OPTION=""
fi

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

restic cache --quiet --cleanup
restic self-update --quiet

echo "Attempting to unlock or initialize repository..."
output=$(run_restic unlock) || { 
  echo "Unlock failed. Running init..."
  output=$(run_restic init) || { 
    echo "Error: Unable to initialize repository."
    send_email
    exit 1
  }
}

echo "Starting backup process..."
output=$(run_restic backup --files-from "$BACKUP_FILE_LIST" $EXCLUDE_OPTION) || { 
  echo "Backup process failed."
  send_email
  exit 1
}

echo "Performing cleanup and retention policies..."
output=$(run_restic forget --keep-daily 7 --keep-weekly 1 --keep-monthly 1 --prune) || { 
  echo "Retention policy execution failed."
  send_email
  exit 1
}

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

echo "Backup process completed successfully."
