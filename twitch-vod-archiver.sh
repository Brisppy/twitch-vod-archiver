#!/bin/bash
# Automatically grabs all video IDs from Twitch for the specified channel, compares them to a list of downloaded
# VODs and downloads any that are missing.

# ARGUMENTS:
# 1: Channel name (e.g Brisppy)

CLIENT_ID= # From channel user
OAUTH_TOKEN= # From channel user
APP_CLIENT_ID= # From dev.twitch.tv
APP_CLIENT_SECRET= # From dev.twitch.tv
VOD_DIRECTORY= # Path to VOD Directory, do NOT end with a slash (/). Users are stored in separate folders within.
SEND_PUSHBULLET= # 0/1, send Pushbullet notificaiton
PUSHBULLET_KEY= # Pushbullet API key

# Check if arguments have been supplied
if [ $# -eq 0 ]; then
	echo "No arguments were supplied."
	exit 1
fi

# Check if VOD directory was set
if [ -z "$VOD_DIRECTORY" ]; then
	echo "No VOD directory set, exiting."
	exit 1
fi

# DO NOT MODIFY
CHANNEL=$1 # Channel name

# Call Twitch API and return the user_id of channel.
USER_ID=$(curl -s -H "Authorization: Bearer $OAUTH_TOKEN" -H "Client-Id: $CLIENT_ID" -X GET https://api.twitch.tv/helix/users?login=$CHANNEL | jq '.data[].id' | sed 's/"//g')
echo "User $CHANNEL ID is $USER_ID"

# Check if the channel is currently live to determine what to do with the currently live VOD.
if [ -z $(curl -s -H "Authorization: Bearer $OAUTH_TOKEN" -H "Client-Id: $CLIENT_ID" -X GET "https://api.twitch.tv/helix/streams?user_id=$USER_ID" | jq '.data[].id') ]; then
	echo "Channel is currently offline."
	CHANNEL_LIVE=false
else
	echo "Channel is currently live. Assuming the highest numbered VOD is still being generated and ignoring."
	CHANNEL_LIVE=true
fi

# Return a list of available VODs from $CHANNEL
AVAILABLE_VODS=$(curl -s -H "Authorization: Bearer $OAUTH_TOKEN" -H "Client-Id: $CLIENT_ID" -X GET "https://api.twitch.tv/helix/videos?user_id=$USER_ID&first=100&type=archive" | jq '.data[].id' | sed 's/"//g' | sed 's/ /\n/g')

# If channel is live, remove the highest numbered VOD (Top of the list.)
if $CHANNEL_LIVE; then
	AVAILABLE_VODS=$(echo "$AVAILABLE_VODS" | tail -n +2)
fi

# Return a list of downloaded VODs
DOWNLOADED_VODS=$(cat $VOD_DIRECTORY/$CHANNEL/downloaded_vods)
echo "Available VODS:"
echo "$AVAILABLE_VODS"
echo "Downloaded VODS:"
echo "$DOWNLOADED_VODS"

NEW_VODS=$(diff -u <(echo "$DOWNLOADED_VODS" | sort) <(echo "$AVAILABLE_VODS" | sort) | grep -v @ | grep + | tail -n +3 | sed 's/+//g')
# Check to see if there are no new VODS
if [ "$NEW_VODS" = "" ]; then
	echo "No new VODs, exiting..."
	exit 0
fi
echo "New VODS:"
echo "$NEW_VODS"

# Iterate through each new VOD
for VOD in $NEW_VODS; do
	echo "Current VOD: $VOD"
	# Get the name of the stream
	VOD_JSON=$(curl -s -H "Authorization: Bearer $OAUTH_TOKEN" -H "Client-Id: $CLIENT_ID" -X GET https://api.twitch.tv/helix/videos?id=$VOD)
	VOD_NAME=$(echo $VOD_JSON | jq '.data[].title' | sed 's/"//g')
	VOD_DATE=$(echo $VOD_JSON | jq '.data[].created_at' | sed 's/"//g')
	VOD_DURATION=$(echo $VOD_JSON | jq '.data[].duration' | sed 's/"//g')
	VOD_SUBDIR="$VOD_DIRECTORY/$CHANNEL/$VOD_DATE - $VOD_NAME - $VOD"
	echo "VOD name is $VOD_NAME, created $VOD_DATE, and is $VOD_DURATION long."
	# Create a directory for the VOD corresponding with its' id
	mkdir -p "$VOD_SUBDIR"
	# Create a file containing the JSON and date.
	echo "$VOD_JSON" > "$VOD_SUBDIR/vod.json"
	# Chat downloader with retry function
	ATTEMPT=0
	while true; do
		# Track attempt number and exit if it exceeds the maximum (5)
		ATTEMPT=$((ATTEMPT+1))
		if [ $ATTEMPT -gt 5 ]; then
			echo "Error downloading chat log. Sending a notification and exiting."
			[ $SEND_PUSHBULLET -eq 1 ] && curl -u $PUSHBULLET_KEY: -d type="note" -d body="Error archiving Twitch VOD $VOD from $CHANNEL on $VOD_DATE. Chat log download error." -d title="Twitch VOD Archiver Error" 'https://api.pushbullet.com/v2/pushes'
			exit 1
		fi
		# Download the chat logs for the VOD
		tcd --video $VOD --format irc --client-id $APP_CLIENT_ID --client-secret $APP_CLIENT_SECRET --output "$VOD_SUBDIR/"
		# Catch error downloading chat log based on last returned code
		ret=$?
		if [ $ret -ne 0 ]; then
			echo "Chat log failed to download, retrying..."
			# Remove the chat log if present
			rm -f "$VOD_SUBDIR/$VOD.log"
			sleep 10
			continue
		else
			# Chat log downloaded successfully, move onto video
			echo "Chat log downloaded successfully."
			break
		fi
	done
	# The method for downloading the actual VOD is quite convoluted in order to resolve an issue with VOD 864884048, a 28HR long VOD which when downloaded, never was the correct length.
	# For some reason the downloaded .ts files have incorrect timestamps, with piece 09531.ts having a 'start' value of 95376.766, and the following piece (09532.ts) having a 
	# 'start' value of -56.951689. When combining all of the pieces this produces an error (non-monotonous dts in output stream), resulting in an output file with a shorter duration
	# than the original VOD.
	# To resolve this, the .ts files are combined with ffmpeg using their numbered order rather than included start value or .m3u8 playlist.
	# Download the VOD via twitch-dl
	TMP="$VOD_SUBDIR" twitch-dl download --no-join -q source $VOD
	if [ $ret -ne 0 ]; then
		echo "Error downloading VOD. Sending a notification and exiting."
		[ $SEND_PUSHBULLET -eq 1 ] && curl -u $PUSHBULLET_KEY: -d type="note" -d body="Error archiving Twitch VOD $VOD from $CHANNEL on $VOD_DATE. VOD download error." -d title="Twitch VOD Archiver Error" 'https://api.pushbullet.com/v2/pushes'
		exit 1
	fi
	# Combine the .ts files
	cat "$VOD_SUBDIR/twitch-dl/"*"/chunked/"*.ts | ffmpeg -y -i pipe: -c:a copy -c:v copy "$VOD_SUBDIR/$VOD_NAME.mp4"
	# Count the number of columns within the VOD_DURATION variable
	VOD_DURATION_SPLIT=$(echo $VOD_DURATION | sed 's/h/:/g' | sed 's/m/:/g' | sed 's/s//g')
	VOD_DURATION_COLUMNS=$(echo $VOD_DURATION_SPLIT | tr ':' '\n' | wc -l)
	# Get the length in seconds based on the number of columns by multiplying each number by the appropriate amount.
	if [ $VOD_DURATION_COLUMNS = 3 ];then
		VOD_DURATION_SECONDS=$(echo $VOD_DURATION_SPLIT | awk -F':' '{ print ($1 * 3600) + ($2 * 60) + $3 }')
	elif [ $VOD_DURATION_COLUMNS = 2 ];then
		VOD_DURATION_SECONDS=$(echo $VOD_DURATION_SPLIT | awk -F':' '{ print ($1 * 60) + $2 }')
	elif [ $VOD_DURATION_COLUMNS = 1 ];then
		VOD_DURATION_SECONDS=$(echo $VOD_DURATION_SPLIT)
	fi
	echo "Duration in seconds of VOD is $VOD_DURATION_SECONDS"
	# Get the length of the downloaded file
	DOWNLOADED_DURATION=$(ffprobe -i "$VOD_SUBDIR/$VOD_NAME.mp4" -show_format -v quiet | sed -n 's/duration=//p' | xargs printf %.0f)
	echo "Expected duration is "$VOD_DURATION_SECONDS"s, downloaded duration is "$DOWNLOADED_DURATION"s"
	# Compare the length of the VOD to the downloaded file
	if [ "$DOWNLOADED_DURATION" -ge "$((VOD_DURATION_SECONDS - 3))" ] && [ "$DOWNLOADED_DURATION" -le "$((VOD_DURATION_SECONDS + 3))" ]; then
		echo "Files are within 3 seconds."
		# Remove the temporary twitch-dl directory containing the .ts files
		rm -dr "$VOD_SUBDIR/twitch-dl"
		# Add VOD to file to keep track of what has been downloaded
		echo "$VOD" >> "$VOD_DIRECTORY/$CHANNEL/downloaded_vods"
	else
		echo "Files have different durations. sending a notification and exiting."
		[ $SEND_PUSHBULLET -eq 1 ] && curl -u $PUSHBULLET_KEY: -d type="note" -d body="Error archiving Twitch VOD $VOD from $CHANNEL on $VOD_DATE. VOD duration mismatch." -d title="Twitch VOD Archiver Error" 'https://api.pushbullet.com/v2/pushes'
		exit 1
	fi
done
