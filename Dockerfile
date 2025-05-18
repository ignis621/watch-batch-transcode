# Base image from linuxserver.io providing FFmpeg
FROM lscr.io/linuxserver/ffmpeg:amd64-7.1.1

# Set working directory inside the container
WORKDIR /app

# Copy the processing script into the container's working directory
COPY process_videos.sh .

# Make the script executable
RUN chmod +x ./process_videos.sh

# Set default PUID and PGID.
# These can be overridden in docker-compose.yaml or via `docker run -e PUID=...`
# The base image uses these to set user permissions for file access.
ENV PUID=1000
ENV PGID=1000

# The linuxserver.io base image has its own init system (s6-overlay)
# which handles user setup and execution. We just need to specify the command.
# CMD ["/app/process_videos.sh"]
ENTRYPOINT ["/bin/bash", "/app/process_videos.sh"]
