#!/bin/sh
# Autore: Alessandro Rovetto
#
# versione: 2.1 --> Aggiunto il controllo sulla raggiungibilità di easyreplay e il file di lock per proibire le esecuzione simultanee
# versione: 2.2 --> mavigano --> fixato il bug 6402
# versione: 2.3 --> mavigano --> fixato il bug 6459
# versione: 2.4 --> arovetto: normalized audio channel order (bug6597)

#############################################################################################
_exit()
{
        rm -f "${LOCKFILE}"
}

#############################################################################################

function computeSlots {
		slotNum=`curl -s "$calldataUrl?mode=getnumslots&callid=$callid&duplicated=$1"`
		let "lastIndex=$slotNum - 1"
		echo SlotNum: $slotNum - $lastIndex
		lastfile=""
		for i in `seq 0 $lastIndex`; do
			slotStr=`curl -s "$calldataUrl?mode=getslotbyid&callid=$callid&id=$i&duplicated=$1"`
			echo SlotStr: $slotStr
			slot=($slotStr)
			if  [ ${#slot[@]} -eq 1 ] || { [ ${slot[0]} == "0" ] && [ ${slot[1]} == "-1" ]; } 
			then
				#No need to cut file
				echo "No need to cut file"
				length=0
			else
				if [ ${slot[1]} == "-1" ]
				then
					length=-1
				else
					length=`echo "${slot[1]} - ${slot[0]}" | bc | sed "s/^\./0./" `
				fi
			fi
			echo "Slot:$slot - Length: $length - Join: ${slot[2]}"

			calldata=`curl -s "$calldataUrl?mode=maketagfilebyid&callid=$callid&id=$i&duplicated=$1"`
			if [ -n "$calldata" ]
			then
				stereofile=$dest_path/${callid}_$1_$i.wav
				if ((  $(echo "$length != 0" | bc -l) ))
				then
					if ((  $(echo "$length == -1" | bc -l) ))
					then
						echo "$ffmpegcmd -i $fullaudiofile -ss ${slot[0]}  -c copy $stereofile"
						$ffmpegcmd -i $fullaudiofile -ss ${slot[0]}  -c copy $stereofile
					else
						echo "$ffmpegcmd -i $fullaudiofile -ss ${slot[0]} -t $length  -c copy $stereofile"
						$ffmpegcmd -i $fullaudiofile -ss ${slot[0]} -t $length -c copy $stereofile
					fi
						
				else
					echo "No need to cut file"
					cp -p $fullaudiofile $stereofile
				fi
				
				regexp=".*switchChannel:[[:space:]]*true.*"

	        	if [[ $calldata =~ $regexp ]] 
				then
					echo "Switch audio channel"
					$ffmpegcmd -i $stereofile -map_channel 0.0.1 -map_channel 0.0.0 $stereofile.tmp.wav
					mv -f $stereofile.tmp.wav $stereofile
				fi

				touch -r $file $stereofile
				
				if [ ${slot[2]} == "TRUE" ]
				then
					##concat file with previous one
					echo "file $lastfile" > temp.txt
		            echo "file $stereofile" >> temp.txt
        			$ffmpegcmd  -safe 0 -f concat -i temp.txt  -c copy $lastfile.tmp.wav  #$dest_path/$callid.wav
					rm -f $lastfile $stereofile temp.txt
					mv $lastfile.tmp.wav $lastfile
				else
					lastfile=$stereofile
				fi
				# SET newfile timestamp as the original one
	        	        touch -r $file $lastfile


				echo "STEREO file: $lastfile"

				# Use different sox command line based on Sox version because of the broken backward compatibility	
				if [ $soxVer -le 12 ]; then
					length=`sox $lastfile -e stat 2>&1 | grep Length | sed 's/Length.*:\s*\(\w*\)/\1/'`
					echo "Length is $length using sox ver < 12"
				else
					length=`sox $lastfile -n stat 2>&1 | grep Length | sed 's/Length.*:\s*\(\w*\)/\1/'`
					echo "Length is $length using sox ver >= 12"
				fi
				
				echo "SoxVer: $soxVer and length: $length"

				dur=`echo "$length *1000" | bc`
				dur=${dur%.*}

				# BUILD tags file using lastfile filename 
			    lastbasename=$(basename "$lastfile")
        		lastbasename="${lastbasename%.*}"

				calldatafile=$dest_path/${lastbasename}.tags
				echo "Calldatafile is $calldatafile"
				echo "Duration: $dur" >  $calldatafile
				echo "$calldata" >> $calldatafile
				echo "RecorderAddr: `hostname -i`" >> $calldatafile
				touch -r $file $calldatafile
			else
				echo "Call $callid has not been established"
			fi
		done
}

cd $1;
dest_path=$2
if [ ! -z $3 ] ; then toerep=$3 ; fi
exportFilter="" #regexp to export only matching files
if [ $# -ge 5 ]; then
	exportFilter=$5
fi

extractaudio_cmd=/usr/local/bin/extractaudio
LOCKFILE=/tmp/.extractaudio.lock



phphost=localhost
if [ $# -ge 4 ]; then
	phphost=$4
fi

calldataUrl=http://$phphost/stereo_recording/stereo_recording.php

soxVer=`sox -h | head -1 | sed 's/.*SoX v\([0-9]*\).*/\1/'`
#soxVer=12;
searchRTPFile="find *.a.rtp -mmin +1";
ffmpegcmd=/usr/local/bin/ffmpeg

echo -e "++++++++++++++++INIZIO ESECUZIONE+++++++++++++ PID: $$"
echo -e "$(date)\n\n"

lockfile -r0 "${LOCKFILE}" &>/dev/null
if [ $? -ne 0 ]
then
        echo -e "[ERROR] Esiste già un'istanza attiva dello script. Non procedo"	
		echo -e "++++++++++++++++FINE ESECUZIONE+++++++++++++ PID: $$"
		echo -e "$(date)\n\n"
		exit 1
fi

trap _exit EXIT
trap '' 2


for file in `$searchRTPFile`; do
	file_mod=${file/.a.rtp/}
	echo "Processing file $file_mod"
	if [ -s $file ]
	then 
		callid=`echo $file_mod | sed 's/=.*//'`
		echo CallID: $callid
		fullaudiofile=$dest_path/$callid.tmp
		$extractaudio_cmd -n -s $file_mod $fullaudiofile
		echo "Extract audio $file_mod result:[$?]"

		computeSlots 0
		computeSlots 1
		
		#Start cleanup data procedure
		curl -s "$calldataUrl?mode=cleanup&callid=$callid"
		rm -f $fullaudiofile
	fi	
	rm -f $file_mod*.rtp



	if [ ! -z $toerep ] && [ "$toerep" == "true" ]
 	then

	# controllo la raggiungibilità della macchina easyreplay
	ping -f -c 1 -i 0.2  easyreplay &> /dev/null

	if [ ! $? -eq 0 ]
	then
		echo -e "[ERROR]Non raggiungo il server easyreplay."
		echo -e "[ERROR]Non posso spostare i file .wav in easyreplay"
		echo -e "++++++++++++++++FINE ESECUZIONE+++++++++++++ PID: $$"
		echo -e "$(date)\n\n"
		# Quando esco perchè non riesco a raggiungere easyreplay differenzio l'exit code
		exit 2
		
	fi
	for f in $(ls $dest_path/*.wav)
	do

		#export only matching files
		tagFile=${f/wav/tags}

		if [ -z "${exportFilter}" ]
		then 
			matchTagFile=0
		else 
			egrep -l "${exportFilter}" $tagFile >> /dev/null
			matchTagFile=$?
		fi
		
		if [ $matchTagFile -eq 0 ]
		then
			echo "Export file $f"
			/opt/reitek/ct6/bin/movetorecorder.sh easyreplay /etc/opt/reitek/sems/etc/CTRecorder.conf $f	&& rm -f $f && echo "File $f transferred to Easyreplay..." && rm -f $tagFile
		fi
	done
	fi
done

echo -e "++++++++++++++++FINE ESECUZIONE+++++++++++++ PID: $$"
echo -e "$(date)\n\n"

trap 2
exit 0
