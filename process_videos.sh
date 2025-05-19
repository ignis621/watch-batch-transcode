#!/bin/bash

# >>> Configuration <<<
INPUT_DIR="/sources"
SOURCES_PROCESSED_DIR="/sources_processed" # Dir to hold original files after processing attempts
OUTPUT_DIR="/completed"     # Dir for final successfully encoded files
ERROR_DIR="/failed"         # Dir for files that failed processing
TEMP_DIR="/tmp"             # Temp dir
CSV_FILE="${OUTPUT_DIR}/.processed_files.csv"

# FFmpeg default settings (can be overridden by environment variables)
DEFAULT_VIDEO_CODEC="libx265"
DEFAULT_VIDEO_CRF="24"
DEFAULT_VIDEO_PRESET="medium"
DEFAULT_AUDIO_CODEC="libopus"
DEFAULT_AUDIO_BITRATE="96k"

# Processing settings
MAX_RETRIES=3 # Total attempts for each file
RETRY_DELAY_SECONDS=5 # Delay between retries

TEMP_SUFFIXES=("part" "tmp" "temp" "crdownload" "download" "partial")

# >>> Helper functions <<<

# Function to log messages
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to get file size in bytes
get_file_size_bytes() {
  stat -c%s "$1"
}

# function to escape a field for CSV output
escape_csv_field() {
    local field="$1"
    local escaped_field="${field//\"/\"\"}" # Replace all " with ""
    if [[ "${escaped_field}" == *","* || "${escaped_field}" == *"\""* ]]; then
        echo "\"${escaped_field}\""
    else
        echo "${escaped_field}"
    fi
}

# function to send a message with NTFY if NTFY_TOPIC is set
ntfy_send() {
    local message="$1"
    if [[ -n "${NTFY_TOPIC}" ]]; then
        # use custom server if set, otherwise default to public
        local ntfy_server="${NTFY_SERVER:-https://ntfy.sh}"
        log_message "Sending notification via ntfy (${ntfy_server}): ${message}"
        # using curl to send the message to ntfy.sh or custm server
        curl -s -d "${message}" "${ntfy_server}/${NTFY_TOPIC}" > /dev/null
         if [ $? -ne 0 ]; then
             log_message "WARNING: Failed to send ntfy notification."
         fi
    fi
}

# function to check if a file is ready for processing (not being written to mostly)
is_file_ready_for_processing() {
    local file_path="$1"
    local filename=$(basename "$file_path")

    log_message "Checking readiness for: ${filename}"

    # check for temporary suffixes
    for suffix in "${TEMP_SUFFIXES[@]}"; do
        if [[ "$filename" =~ \.${suffix}$ ]]; then
            log_message "Skipping ${filename}: has temporary suffix '.${suffix}'."
            return 1 # not ready
        fi
    done

    # check if any process has the file open for writing
    if lsof +w -- "${file_path}" &> /dev/null; then
        log_message "Skipping ${filename}: file is currently open for writing by another process (lsof check)."
        return 1 # Not ready
    fi

    # check initial file size
    local delay_seconds=2
    log_message "Checking ${filename}: checking file size stability once after ${delay_seconds}s delay..."
    local initial_size=$(get_file_size_bytes "${file_path}")

    if [ "${initial_size}" -eq -1 ]; then
        log_message "Skipping ${filename}: Couldn't get initial file size (file might have disappeared)."
        return 1 # not ready
    fi

    if [ "${initial_size}" -eq 0 ]; then
        log_message "Skipping ${filename}: size is 0 bytes."
        return 1 # not ready
    fi

    local current_size="${initial_size}"
    sleep "${delay_seconds}"
    local new_size=$(get_file_size_bytes "${file_path}")

    if [ "${new_size}" -eq -1 ]; then
        log_message "Skipping ${filename}: Couldn't get file size during stability check (file might have disappeared)."
        return 1 # not rdy
    fi

    if [ "${new_size}" -ne "${current_size}" ]; then
        log_message "Skipping ${filename}: size changed during stability check. Still being written? Size change: ${current_size} -> ${new_size}"
        return 1 # not rdy
    fi

    log_message "${filename} seems ready for processing (passed all checks)."
    return 0 # ready
}

# >>>main script logic<<<

log_message "Starting stuff up"
mkdir -p "${INPUT_DIR}"
mkdir -p "${SOURCES_PROCESSED_DIR}"
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${ERROR_DIR}"
mkdir -p "${TEMP_DIR}"

FILE_OVERALL_START_TIME=0

while true; do
  log_message "Scanning ${INPUT_DIR} for files..."
  FIRST_FILE=$(find "${INPUT_DIR}" -maxdepth 1 -type f -print -quit)

  if [ -n "${FIRST_FILE}" ]; then

    if ! is_file_ready_for_processing "${FIRST_FILE}"; then
      sleep 1
      continue
    fi

    FILENAME=$(basename "${FIRST_FILE}")
    PROCESSED_FILE_PATH="${SOURCES_PROCESSED_DIR}/${FILENAME}"
    TEMP_MKV_FILE="${TEMP_DIR}/${FILENAME%.*}.mkv"
    FINAL_MP4_FILE="${OUTPUT_DIR}/${FILENAME%.*}.mp4"

    log_message "Found file: ${FILENAME}. Moving to ${SOURCES_PROCESSED_DIR}."
    mv "${FIRST_FILE}" "${PROCESSED_FILE_PATH}"
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to move ${FIRST_FILE} to ${SOURCES_PROCESSED_DIR}. Skipping."
        sleep 1
        continue
    fi

    INPUT_SIZE_BYTES=$(get_file_size_bytes "${PROCESSED_FILE_PATH}")
    log_message "Input file size (from ${SOURCES_PROCESSED_DIR}): ${INPUT_SIZE_BYTES} bytes"

    SUCCESS=false
    FILE_OVERALL_START_TIME=$(date +%s) # start time for the first attempt for this file

    for attempt in $(seq 1 ${MAX_RETRIES}); do
      log_message "Processing attempt ${attempt}/${MAX_RETRIES} for file ${FILENAME}..."

      # settings for ffmpeg
      VIDEO_CODEC=${VIDEO_CODEC:-$DEFAULT_VIDEO_CODEC}
      VIDEO_CRF=${VIDEO_CRF:-$DEFAULT_VIDEO_CRF}
      VIDEO_PRESET=${VIDEO_PRESET:-$DEFAULT_VIDEO_PRESET}
      AUDIO_CODEC=${AUDIO_CODEC:-$DEFAULT_AUDIO_CODEC}
      AUDIO_BITRATE=${AUDIO_BITRATE:-$DEFAULT_AUDIO_BITRATE}

      log_message "Using Video: ${VIDEO_CODEC} @ CRF ${VIDEO_CRF} (Preset ${VIDEO_PRESET}), Audio: ${AUDIO_CODEC} @ ${AUDIO_BITRATE}"

      log_message "Starting encoding to temporary MKV (Attempt ${attempt})..."
      ffmpeg -y -i "${PROCESSED_FILE_PATH}" \
             -c:v "${VIDEO_CODEC}" -crf "${VIDEO_CRF}" -preset "${VIDEO_PRESET}" \
             -c:a "${AUDIO_CODEC}" -b:a "${AUDIO_BITRATE}" \
             "${TEMP_MKV_FILE}"
      if [ $? -ne 0 ]; then
          log_message "ERROR: FFmpeg encoding failed on attempt ${attempt} for ${FILENAME}."
          rm -f "${TEMP_MKV_FILE}" # clean up failed temp file
          if [ "${attempt}" -lt "${MAX_RETRIES}" ]; then
              log_message "Waiting ${RETRY_DELAY_SECONDS}s before next attempt."
              sleep "${RETRY_DELAY_SECONDS}"
              continue
          else
              log_message "Max retries reached for encoding on ${FILENAME}. File stays in ${SOURCES_PROCESSED_DIR}."
              # no ntfy here yet, cuz remuxing might also fail
              break
          fi
      fi
      log_message "Encoding completed. Temporary MKV: ${TEMP_MKV_FILE}"

      log_message "Remuxing ${TEMP_MKV_FILE} to ${FINAL_MP4_FILE} (Attempt ${attempt})..."

      # this just changes the container, doesnt reencode
      ffmpeg -y -i "${TEMP_MKV_FILE}" -vcodec copy -acodec copy -movflags +faststart "${FINAL_MP4_FILE}"
      if [ $? -ne 0 ]; then
          log_message "ERROR: FFmpeg remuxing failed on attempt ${attempt} for ${FILENAME}."
          rm -f "${TEMP_MKV_FILE}" # remove temporary MKV
          rm -f "${FINAL_MP4_FILE}" # remove potentially borked final file
          if [ "${attempt}" -lt "${MAX_RETRIES}" ]; then
              log_message "Waiting ${RETRY_DELAY_SECONDS}s before next attempt (including re-encoding)."
              sleep "${RETRY_DELAY_SECONDS}"
              continue
          else
              log_message "Max retries reached for Remux/Encoding on ${FILENAME}. File remains in ${SOURCES_PROCESSED_DIR}."
              break
          fi
      fi
      log_message "Remuxing complete. Final MP4: ${FINAL_MP4_FILE}"
      rm -f "${TEMP_MKV_FILE}"
      log_message "Cleaned up temporary MKV file: ${TEMP_MKV_FILE}"

      SUCCESS=true
      PROCESSING_END_TIME=$(date +%s)
      break # exit retry loop, processing was successful
    done

    if [ "${SUCCESS}" = true ]; then
      TOTAL_PROCESSING_TIME_SECONDS=$((PROCESSING_END_TIME - FILE_OVERALL_START_TIME))
      PROCESSING_TIME_FORMATTED=$(date -u -d @"${TOTAL_PROCESSING_TIME_SECONDS}" '+%H:%M:%S')
      OUTPUT_SIZE_BYTES=$(get_file_size_bytes "${FINAL_MP4_FILE}")
      log_message "Output file size (in ${OUTPUT_DIR}): ${OUTPUT_SIZE_BYTES} bytes"

      RATIO="0"
      if [ "${INPUT_SIZE_BYTES}" -gt 0 ]; then
        RATIO=$(awk "BEGIN {printf \"%.2f\", ${OUTPUT_SIZE_BYTES} / ${INPUT_SIZE_BYTES}}")
      fi
      log_message "Size ratio (output/input): ${RATIO}"
      log_message "Total processing time for ${FILENAME}: ${PROCESSING_TIME_FORMATTED}"

      if [ ! -f "${CSV_FILE}" ]; then
        log_message "CSV file ${CSV_FILE} not found. Creating with headers."
        echo "filename,input_size_bytes,output_size_bytes,ratio,processing_time_HHMMSS" > "${CSV_FILE}"
      fi

      ESCAPED_FILENAME=$(escape_csv_field "${FILENAME}")
      echo "${ESCAPED_FILENAME},${INPUT_SIZE_BYTES},${OUTPUT_SIZE_BYTES},${RATIO},${PROCESSING_TIME_FORMATTED}" >> "${CSV_FILE}"
      log_message "Appended processing info for ${ESCAPED_FILENAME} to ${CSV_FILE}."

      # send ntfy notification for success
      ntfy_send "✅ Successfully transcoded ${FILENAME} (${PROCESSING_TIME_FORMATTED})"

      # Check for DELETE_AFTER env var and delete if set
      if [[ -n "${DELETE_AFTER}" ]]; then
          log_message "DELETE_AFTER environment variable is set. Removing successfully processed source file ${PROCESSED_FILE_PATH}."
          rm -f "${PROCESSED_FILE_PATH}"
          if [ $? -ne 0 ]; then
              log_message "ERROR: Failed to remove ${PROCESSED_FILE_PATH} after successful processing."
              ntfy_send "⚠️ Failed to remove source file ${FILENAME} after successful transcoding! - investigate, it should NOT happen."
          fi
      else
          log_message "DELETE_AFTER environment variable is not set. Keeping source file ${PROCESSED_FILE_PATH}."
      fi

    else
      log_message "All ${MAX_RETRIES} processing attempts failed for ${FILENAME}. Moving to ${ERROR_DIR}."
      # the og source file moves from ${SOURCES_PROCESSED_DIR} to ${ERROR_DIR}
      mv "${PROCESSED_FILE_PATH}" "${ERROR_DIR}/${FILENAME}"
      if [ $? -ne 0 ]; then
          log_message "Failed to move ${PROCESSED_FILE_PATH} to ${ERROR_DIR}/${FILENAME} after all retries failed."
          # send ntfy if move fails, this means something's seriously wrong
          ntfy_send "⚠️ Failed to move failed file ${FILENAME} to ${ERROR_DIR}! - investigate, it should NOT happen."
      else
          log_message "Moved ${FILENAME} to ${ERROR_DIR}."
          # send ntfy notification for failure
          ntfy_send "❌ Failed to transcode ${FILENAME} after ${MAX_RETRIES} attempts"
      fi
      # clean up any leftovers just in case (shouldn't be any but better safe than holy 50GB /temp dir)
      rm -f "${TEMP_MKV_FILE}"
    fi
  else
    log_message "No files found in ${INPUT_DIR}. Waiting 1s."
    sleep 1
  fi
  log_message "Waiting 1s before next scan"
  sleep 1
done

log_message "Script finished, something's seriously wrong - this should not happen"
ntfy_send "⚠️ Script finished! - investigate, it should NOT happen."
