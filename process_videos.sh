#!/bin/bash

#########################
# >>> CONFIGURATION <<< #
#########################
INPUT_DIR="/sources"                       # Dir for input files, this is the one that's scanned
SOURCES_PROCESSED_DIR="/sources_processed" # Dir to hold original files after processing attempts
OUTPUT_DIR="/completed"                    # Dir for final successfully encoded files
ERROR_DIR="/failed"                        # Dir for files that failed processing
TEMP_DIR="/tmp"                            # Temp dir
CSV_FILE="${OUTPUT_DIR}/.processed_files.csv"

# Override FFmpeg arguments (highest priority)
OVERRIDE_ENCODE_ARGS="${OVERRIDE_ENCODE_ARGS:-}" # example OVERRIDE_ENCODE_ARGS="-c:v libx264 -b:v 2000k -preset slow -c:a aac -b:a 128k"
OVERRIDE_REMUX_ARGS="${OVERRIDE_REMUX_ARGS:-}" # not sure why anyone would touch that but i'll add it for the sake of flexibility
# Final video container format (eg., mp4, mkv, webm)
FINAL_VIDEO_CONTAINER="${FINAL_VIDEO_CONTAINER:-mp4}"

# individual ffmpeg variables, for simple basic configuration
VIDEO_CODEC="${VIDEO_CODEC:-libx265}"
VIDEO_CRF="${VIDEO_CRF:-22}"
VIDEO_PRESET="${VIDEO_PRESET:-medium}"
AUDIO_CODEC="${AUDIO_CODEC:-libopus}"
AUDIO_BITRATE="${AUDIO_BITRATE:-96k}"

# Processing settings
MAX_RETRIES=3 # Total attempts for each file
RETRY_DELAY_SECONDS=5 # Delay between retries

TEMP_SUFFIXES=("part" "tmp" "temp" "crdownload" "download" "partial")

# Vars to track current state for graceful shutdown
CURRENT_PROCESSING_FILE=""
FFMPEG_PID=""

############################
# >>> HELPER FUNCTIONS <<< #
############################

# Function to log messages
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to get file size in bytes
get_file_size_bytes() {
  stat -c%s "$1" 2>/dev/null || echo "-1" # will return -1 if file not found or other error
}

# Function to escape a field for CSV output
escape_csv_field() {
  local field="$1"
  local escaped_field="${field//\"/\"\"}"
  echo "\"${escaped_field}\""
}

# Function to send a message with NTFY if NTFY_TOPIC is set
ntfy_send() {
  local message="$1"
  if [[ -n "${NTFY_TOPIC}" ]]; then
    # use custom server if set, otherwise default to public
    local ntfy_server="${NTFY_SERVER:-https://ntfy.sh}"
    log_message "Sending notification via ntfy (${ntfy_server}): ${message}"
    # using curl to send the message to ntfy.sh or custom server
    curl -s -d "${message}" "${ntfy_server}/${NTFY_TOPIC}" > /dev/null
    if [ $? -ne 0 ]; then
      log_message "ERROR: Failed to send ntfy notification."
    fi
  fi
}

# Function to check if a file is ready for processing (not still being moved/written to)
is_file_ready_for_processing() {
  local file_path="$1"
  local filename=$(basename "$file_path")

  log_message "Checking readiness for: ${filename}"

  # check for temporary suffixes, might still be downloading or moving to share
  for suffix in "${TEMP_SUFFIXES[@]}"; do
    if [[ "$filename" =~ \.${suffix}$ ]]; then
      log_message "Skipping ${filename}: has temporary suffix '.${suffix}'."
      return 1 # not ready
    fi
  done

  # check if any process has the file open for writing using lsof
  if lsof +w -- "${file_path}" &> /dev/null; then
    log_message "Skipping ${filename}: file is currently open for writing by another process (lsof check)."
    return 1 # Not ready
  fi

  # check file size stability over a short delay
  local delay_seconds=2
  log_message "Checking ${filename}: checking file size stability once after ${delay_seconds}s delay..."
  local initial_size=$(get_file_size_bytes "${file_path}")

  # if initial size check failed or file is empty
  if [ "${initial_size}" -eq -1 ]; then
    log_message "Skipping ${filename}: Couldn't get file size (file might have disappeared)."
    return 1 # not ready
  fi

  # check if initial size is 0 bytes
  if [ "${initial_size}" -eq 0 ]; then
    log_message "Skipping ${filename}: size is 0 bytes."
    return 1 # not ready
  fi

  # wait for a bit
  local current_size="${initial_size}"
  sleep "${delay_seconds}"
  local new_size=$(get_file_size_bytes "${file_path}")

  # if second size check failed during the second check
  if [ "${new_size}" -eq -1 ]; then
    log_message "Skipping ${filename}: Couldn't get file size (file might have disappeared)."
    return 1 # not rdy
  fi

  # compare size
  if [ "${new_size}" -ne "${current_size}" ]; then
    log_message "Skipping ${filename}: size changed during stability check. Still being written? Size change: ${current_size} -> ${new_size}"
    return 1 # not rdy
  fi

  log_message "${filename} seems ready for processing (passed all checks)."
  return 0 # ready
}


# Function to handle graceful shutdown
graceful_shutdown() {
  log_message "Caught SIGTERM. Starting graceful shutdown."

  # If FFmpeg is running, send it a SIGKILL, we don't want to wait
  if [[ -n "${FFMPEG_PID}" ]]; then
    log_message "Sending SIGKILL to ffmpeg process ${FFMPEG_PID}"
    kill -9 "${FFMPEG_PID}" 2>/dev/null
    wait "${FFMPEG_PID}" 2>/dev/null
    log_message "FFmpeg process ${FFMPEG_PID} terminated."
  fi

  # Move back the file
  if [[ -n "${CURRENT_PROCESSING_FILE}" && -f "${SOURCES_PROCESSED_DIR}/${CURRENT_PROCESSING_FILE}" ]]; then
    log_message "Moving ${CURRENT_PROCESSING_FILE} back to ${INPUT_DIR}."
    mv "${SOURCES_PROCESSED_DIR}/${CURRENT_PROCESSING_FILE}" "${INPUT_DIR}/${CURRENT_PROCESSING_FILE}"
  fi

  # Clean up temp files
  log_message "Cleaning up temporary directory ${TEMP_DIR}."
  rm -rf "${TEMP_DIR}"/* # Clean contents, not the dir itself

  log_message "Graceful shutdown complete. Exiting."
  exit 0
}

# Set the trap for SIGTERM
trap graceful_shutdown SIGTERM

##########################
# >>> SCRIPT STARTUP <<< #
##########################

log_message "Starting up..."

mkdir -p "${INPUT_DIR}"
mkdir -p "${SOURCES_PROCESSED_DIR}"
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${ERROR_DIR}"
mkdir -p "${TEMP_DIR}"

# if it already exists, clean it up
rm -rf "${TEMP_DIR}"/*

##############################
# >>> ENCODING ARGUMENTS <<< #
##############################

ENCODING_ARGS_ARRAY=()
if [[ -n "${OVERRIDE_ENCODE_ARGS}" ]]; then
  # read space separated string into array
  read -ra ENCODING_ARGS_ARRAY <<< "${OVERRIDE_ENCODE_ARGS}"
else
  # if no override args, use these:
  ENCODING_ARGS_ARRAY=(
    -c:v "${VIDEO_CODEC}"
    -crf "${VIDEO_CRF}"
    -preset "${VIDEO_PRESET}"
    -c:a "${AUDIO_CODEC}"
    -b:a "${AUDIO_BITRATE}"
    -loglevel 16
    -nostats
  )
fi

log_message "Encoding args: ${ENCODING_ARGS_ARRAY[*]}"

# set remuxing arguments
REMUX_ARGS_ARRAY=()
if [[ -n "${OVERRIDE_REMUX_ARGS}" ]]; then
  # read space separated string into array
  read -ra REMUX_ARGS_ARRAY <<< "${OVERRIDE_REMUX_ARGS}"
else
  # if no override args, use these:
  REMUX_ARGS_ARRAY=(
    -vcodec copy
    -acodec copy
    -movflags +faststart
    -hide_banner
    -loglevel 16
    -nostats
  )
fi

log_message "Remuxing args: ${REMUX_ARGS_ARRAY[*]}"

################################
# >>> MAIN PROCESSING LOOP <<< #
################################

FILE_OVERALL_START_TIME=0

while true; do
  log_message "Scanning ${INPUT_DIR} for files..."
  # find the first file (non-recursively) and exit find immediately
  FIRST_FILE=$(find "${INPUT_DIR}" -maxdepth 1 -type f -print -quit)

  # check if a file was found
  if [ -n "${FIRST_FILE}" ]; then

    # check if the file is ready for processing
    if ! is_file_ready_for_processing "${FIRST_FILE}"; then
      sleep 1 # wait a bit before checking again if not ready
      continue # skip to the next iteration of the while loop
    fi

    FILENAME=$(basename "${FIRST_FILE}")
    PROCESSED_FILE_PATH="${SOURCES_PROCESSED_DIR}/${FILENAME}"
    # Use .mkv for the temporary file regardless of the final container, it's a good intermediate format
    TEMP_INTERMEDIATE_FILE="${TEMP_DIR}/${FILENAME%.*}.mkv"
    # Construct the final output file name using the base name and the chosen container
    FINAL_OUTPUT_FILE="${OUTPUT_DIR}/${FILENAME%.*}.${FINAL_VIDEO_CONTAINER}"

    log_message "Found file: ${FILENAME}. Moving to ${SOURCES_PROCESSED_DIR}."
    # move the file to the 'processed' directory before starting work
    mv "${FIRST_FILE}" "${PROCESSED_FILE_PATH}"

    CURRENT_PROCESSING_FILE="${FILENAME}"
    FFMPEG_PID="" # Reset PID for the new file

    INPUT_SIZE_BYTES=$(get_file_size_bytes "${PROCESSED_FILE_PATH}")
    log_message "Input file size (from ${SOURCES_PROCESSED_DIR}): ${INPUT_SIZE_BYTES} bytes"

    SUCCESS=false
    # record the start time for the first attempt on this file
    FILE_OVERALL_START_TIME=$(date +%s)

    # retry loop for processing the current file
    for attempt in $(seq 1 ${MAX_RETRIES}); do
      log_message "Processing attempt ${attempt}/${MAX_RETRIES} for file ${FILENAME}..."

      log_message "Starting encoding to temporary MKV (Attempt ${attempt})..."
      # execute ffmpeg command with the encoding args set before, capture PID
      ffmpeg -y -i "${PROCESSED_FILE_PATH}" \
             "${ENCODING_ARGS_ARRAY[@]}" \
             "${TEMP_INTERMEDIATE_FILE}" & # Run in background to capture PID
      FFMPEG_PID=$! # Capture the PID of the background ffmpeg process
      log_message "FFmpeg encoding started with PID: ${FFMPEG_PID}"

      wait "${FFMPEG_PID}" # Wait for the background ffmpeg process to finish
      ENCODE_EXIT_STATUS=$?
      FFMPEG_PID="" # Clear PID after process finishes

      # check the exit status of the ffmpeg command
      if [ ${ENCODE_EXIT_STATUS} -ne 0 ]; then
        log_message "ERROR: FFmpeg encoding failed on attempt ${attempt} for ${FILENAME} (Exit Status: ${ENCODE_EXIT_STATUS})."
        rm -f "${TEMP_INTERMEDIATE_FILE}" # clean up failed temp file
        # check if there are more retries left
        if [ "${attempt}" -lt "${MAX_RETRIES}" ]; then
          log_message "Waiting ${RETRY_DELAY_SECONDS}s before next attempt."
          sleep "${RETRY_DELAY_SECONDS}"
          continue # continue to the next attempt in the retry loop
        else
          log_message "Max retries reached for encoding on ${FILENAME}. File stays in ${SOURCES_PROCESSED_DIR}."
          break # exit retry loop if max retries are hit
        fi
      fi
      log_message "Encoding completed. Temporary intermediate file: ${TEMP_INTERMEDIATE_FILE}"

      log_message "Remuxing ${TEMP_INTERMEDIATE_FILE} to ${FINAL_OUTPUT_FILE} (Attempt ${attempt})..."
      # execute ffmpeg command with the remuxing args set before, capture PID
      ffmpeg -y -i "${TEMP_INTERMEDIATE_FILE}" \
             "${REMUX_ARGS_ARRAY[@]}" \
             "${FINAL_OUTPUT_FILE}" & # run in background
      FFMPEG_PID=$! # capture the PID of the background ffmpeg process
      log_message "FFmpeg remuxing started with PID: ${FFMPEG_PID}"

      wait "${FFMPEG_PID}" # wait for the background ffmpeg process to finish
      REMUX_EXIT_STATUS=$?
      FFMPEG_PID="" # clear PID after process finishes

      # check the exit status of the ffmpeg command
      if [ ${REMUX_EXIT_STATUS} -ne 0 ]; then
        log_message "ERROR: FFmpeg remuxing failed on attempt ${attempt} for ${FILENAME} (Exit Status: ${REMUX_EXIT_STATUS})."
        rm -f "${TEMP_INTERMEDIATE_FILE}" # remove temporary intermediate file
        rm -f "${FINAL_OUTPUT_FILE}" # remove potentially borked final file
        # check if there are more retries left
        if [ "${attempt}" -lt "${MAX_RETRIES}" ]; then
          log_message "Waiting ${RETRY_DELAY_SECONDS}s before next attempt (including re-encoding)."
          sleep "${RETRY_DELAY_SECONDS}"
          continue # continue to the next attempt in the retry loop
        else
          log_message "Max retries reached for Remux/Encoding on ${FILENAME}. File remains in ${SOURCES_PROCESSED_DIR}."
          break # exit retry loop if max retries are hit
        fi
      fi
      log_message "Remuxing complete. Final output: ${FINAL_OUTPUT_FILE}"

      CURRENT_PROCESSING_FILE="" # clear this cause processing for this file is complete

      # clean up the temporary intermediate file after successful remuxing
      rm -f "${TEMP_INTERMEDIATE_FILE}"
      log_message "Cleaned up temporary intermediate file: ${TEMP_INTERMEDIATE_FILE}"

      SUCCESS=true # mark processing as successful
      PROCESSING_END_TIME=$(date +%s) # record the end time
      break # exit retry loop, processing was successful
    done # end of retry loop

    # fail/success logic
    if [ "${SUCCESS}" = true ]; then
      # if it was successful:
      TOTAL_PROCESSING_TIME_SECONDS=$((PROCESSING_END_TIME - FILE_OVERALL_START_TIME))
      PROCESSING_TIME_FORMATTED=$(date -u -d @"${TOTAL_PROCESSING_TIME_SECONDS}" '+%H:%M:%S')
      OUTPUT_SIZE_BYTES=$(get_file_size_bytes "${FINAL_OUTPUT_FILE}")
      log_message "Output file size (in ${OUTPUT_DIR}): ${OUTPUT_SIZE_BYTES} bytes"

      # calculate size ratio, handle division by zero
      RATIO="0"
      if [ "${INPUT_SIZE_BYTES}" -gt 0 ]; then
        RATIO=$(awk "BEGIN {printf \"%.2f\", ${OUTPUT_SIZE_BYTES} / ${INPUT_SIZE_BYTES}}")
      fi
      log_message "Size ratio (output/input): ${RATIO}"
      log_message "Total processing time for ${FILENAME}: ${PROCESSING_TIME_FORMATTED}"

      # append processing info to the CSV file
      # create header if file doesn't exist
      if [ ! -f "${CSV_FILE}" ]; then
        log_message "CSV file ${CSV_FILE} not found. Creating with headers."
        echo "filename,input_size_bytes,output_size_bytes,ratio,processing_time_HHMMSS" > "${CSV_FILE}"
      fi

      ESCAPED_FILENAME=$(escape_csv_field "${FILENAME}")
      echo "${ESCAPED_FILENAME},${INPUT_SIZE_BYTES},${OUTPUT_SIZE_BYTES},${RATIO},${PROCESSING_TIME_FORMATTED}" >> "${CSV_FILE}"
      log_message "Appended processing info for ${ESCAPED_FILENAME} to ${CSV_FILE}."

      # send ntfy notification for success
      ntfy_send "✅ Successfully transcoded ${FILENAME} to ${FINAL_VIDEO_CONTAINER} (${PROCESSING_TIME_FORMATTED})"

      # check for DELETE_AFTER env var and delete source file if set
      if [[ -n "${DELETE_AFTER}" ]]; then
        log_message "DELETE_AFTER environment variable is set. Removing successfully processed source file ${PROCESSED_FILE_PATH}."
        rm -f "${PROCESSED_FILE_PATH}"
      else
        log_message "DELETE_AFTER environment variable is not set. Keeping source file ${PROCESSED_FILE_PATH}."
      fi

    else
      # if failed
      log_message "All ${MAX_RETRIES} processing attempts failed for ${FILENAME}. Moving to ${ERROR_DIR}."
      # move the original source file from processed dir to the error directory
      mv "${PROCESSED_FILE_PATH}" "${ERROR_DIR}/${FILENAME}"
      log_message "Moved ${FILENAME} to ${ERROR_DIR}."
      # send ntfy notification for failure
      ntfy_send "❌ Failed to transcode ${FILENAME} after ${MAX_RETRIES} attempts"
      # ensure temp file is removed on fail too (double-check)
      rm -f "${TEMP_INTERMEDIATE_FILE}"

    fi
  else
    # if no files were found in the input directory
    log_message "No files found in ${INPUT_DIR}. Waiting 1s."
    sleep 1
  fi
  log_message "Waiting 1s before next scan"
  sleep 1
done # end of while true loop

log_message "Script end reached, something's seriously wrong - this should not happen"
