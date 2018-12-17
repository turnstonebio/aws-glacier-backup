#!/bin/bash

# aws-glacier-backup.sh
# March 21, 2018
# David Hunter
#
#d`dddd Prerequisites:
#
# jq - pkg install jq
# pip - pkg install pip
# awscli - pip install awscli
# treehash - https://github.com/jdswinbank/treehash
# bc - if your installation doesn't have it by default

####################
# INITIAL VARIABLES
####################

sourceDir=${1}                                                                      # Base directory
archiveDir=${2}                                                                     # Directory to build archive from
datedArchiveName=${archiveDir}"_"$(date +"%m-%d-%Y_%H%I").tar.gz                    # Concatenated variable with current date for the archive name
chunkSize=4294967296                                                                # Size of split parts, in bytes, for the multipart archive
chunkSizeGiB=$(($chunkSize/1073741824))
chunkSizeMiB=$(($chunkSize/1048576))                                                # This variable included if your version of split does not support GB
vaultName=""                                                                        # Name of AWS Glacier vault
gpgRecipient=""                                                                     # Valid email or key id for GnuPG

############
# FUNCTIONS
############

# If archive doesn't already exists, create tar.gz archive and send stderr of tar operation to manifest file.
function create_archive() {

printf "\nCreating archive of ${archiveDir}\n"
if [[ -f /tmp/${datedArchiveName} ]]; then
        printf "\nFile ${datedArchiveName} already exists! Skipping archive creation.\n"
else
        tar zcvf "/tmp/${datedArchiveName}" "${sourceDir}/${archiveDir}" &> "/tmp/manifest_${archiveDir}.txt"
fi
}

function encrypt_archive() {

printf "\nEncrypting archive with available keys\n"
if [[ -f /tmp/${datedArchiveName}.gpg ]]; then
	printf "\nEncrypted file already exists!\n"
else
	gpg -e --trust-model always --recipient ${gpgRecipient} /tmp/${datedArchiveName}
fi

local retVal=$?
if [ $retVal -ne 0 ]; then
	printf "\nEncryption failed!\n"
	exit 1
else
	sleep 1
	mv -f /tmp/${datedArchiveName}.gpg /tmp/${datedArchiveName}
fi

archiveSize=$(wc -c "/tmp/${datedArchiveName}" | awk '{ print $1 }')

}

# Split the archive into $chunkSize chunks/parts, if $archiveSize is greater than 4GiB
function split_archive() {

printf "\nSplitting archive into ${chunkSizeGiB}GiB chunks\n"
split -d -a 4 -b ${chunkSizeGiB}G "/tmp/${datedArchiveName}" "/tmp/${datedArchiveName}".

}

# Compute treehash of archive; required for all uploads
function compute_treehash() {

printf "\nCalculating treehash of ${datedArchiveName}\n"
TREEHASH=$(treehash "/tmp/${datedArchiveName}" | awk '{ print $2 }')
printf "\n${TREEHASH}\n"

}

# Calcuate the range necessary to iterate over for a multi-part upload.  This is derived from the extension of the
# last part of the split archive.
function calculate_range() {
range=$(printf '%s\n' "/tmp/${datedArchiveName}".???? | tail -1 | cut -d . -f 4 | bc)

# And take back one kadam to honor the Hebrew God whose Ark this is.
range=$((range-1))

# Check to see if the result is actually an integer. Abort if not.
if ! [[ "$range" =~ ^[0-9]+$ ]]
# if ! echo "$range" | grep -q '[0-9]';
        then
            printf "\nError! ${range} is not an integer. Aborting!\n"
            exit 1
fi

}

# Initiate a single file upload for archives smaller than 4GiB
function upload_single() {

printf "\nInitiating single upload to Glacier\n"
aws glacier upload-archive --account-id - --vault-name "${vaultName}" --checksum "${TREEHASH}" --archive-description "${archiveDir} archived on $(date +"%m-%d-%Y_%H%I")" --body "/tmp/${datedArchiveName}" >> "/tmp/meta_upload_complete_${datedArchiveName}.json"

}

# Initiate multi-part upload to AWS Glacier and capture upload-id
function upload_multipart() {

printf "\nInitiating multipart upload to Glacier...generating upload-id...\n"
aws glacier initiate-multipart-upload --account-id - --archive-description "${archiveDir} archived on $(date +"%m-%d-%Y_%H%I")" --part-size ${chunkSize} --vault-name ${vaultName} > "/tmp/meta_upload_init_${datedArchiveName}.json"
UPLOADID=$(jq -r '.uploadId' "/tmp/meta_upload_init_${datedArchiveName}.json")

# This loop uploads all 4GiB chunks; the last chunk is calculated and uploaded separately
for i in $(seq 0 ${range}); do
    # Calculate byte range from sequence number
    local k=$(( $i + 1 ))
    local lowerByteBound=$(( $k*$chunkSize-$chunkSize ))
    local upperByteBound=$(( $k*$chunkSize-1 ))
    # Upload that part
    printf "\nUploading part ${partNum[$i]}\n"
    printf "\nLower bound: ${lowerByteBound}\nUpper bound: ${upperByteBound}\n"
    aws glacier upload-multipart-part --upload-id "${UPLOADID}" --body "/tmp/${datedArchiveName}.${partNum[$i]}" --range "bytes ${lowerByteBound}-${upperByteBound}/*" --account-id - --vault-name ${vaultName}
done

# Calculate bounds for final chunk and upload
local lowerByteBound=$((upperByteBound+1))
local upperByteBound=$((archiveSize-1))
printf "\nLower bound: ${lowerByteBound}\nUpper bound: ${upperByteBound}\n"
printf "\nUploading final part\n"

aws glacier upload-multipart-part --upload-id "${UPLOADID}" --body "/tmp/${datedArchiveName}.${partNum[-1]}" --range "bytes ${lowerByteBound}-${upperByteBound}/*" --account-id - --vault-name ${vaultName}

# Complete multipart upload with $TREEHASH value
printf "\nCompleting multipart upload\n"
aws glacier complete-multipart-upload --checksum "${TREEHASH}" --archive-size ${archiveSize} --upload-id "${UPLOADID}" --account-id - --vault-name ${vaultName} >> "/tmp/meta_upload_complete_${datedArchiveName}.json"

}

# If the upload was successful, then you should get a 138 byte length key value in the .json for archiveId.
function check_upload() {

ARCHIVEID=$(cat "/tmp/meta_upload_complete_${datedArchiveName}.json" | jq -e -r '.archiveId')
ARCHIVEID_LEN=${#ARCHIVEID}

if [[ "${ARCHIVEID_LEN}" -eq "138" ]]; then
    printf "\nArchiveID ${ARCHIVEID} valid for this upload\n"
else
    if [[ ${archiveSize} -lt ${chunkSize} ]]; then
        printf "\nInvalid or non-existsent ArchiveId. No mechanism to abort single part uploads. Hope everything is ok.\n"
        exit 1
    else
        printf "\nInvalid or non-existsent ArchiveId. Attempting to abort multi-part upload\n"
        aws glacier abort-multipart-upload --upload-id ${UPLOADID} --account-id - --vault-name ${vaultName}
        exit 1
    fi
fi

}

# This populates an array with the 4 digit extensions generated by split so they can be referenced by the
# "aws glacier upload-multipart-part" command.
function init_array() {

local j=0
for file in "/tmp/${datedArchiveName}".*
do
        if [[ -f ${file} ]]; then
                partNum[$j]=$(echo ${file} | cut -d . -f 4)
                j=$(($j+1))
        fi
done

}

# Post upload clean up
function clean_up() {

local jobsDirName="${archiveDir}_$(date +"%m-%d-%Y_%H%I")"
mkdir -p "/opt/aws-glacier-backup/COMPLETED_JOBS/${jobsDirName}"
mv "/tmp/manifest_${archiveDir}.txt" "/opt/aws-glacier-backup/COMPLETED_JOBS/${jobsDirName}/"
mv "/tmp/meta_upload_complete_${datedArchiveName}.json" "/opt/aws-glacier-backup/COMPLETED_JOBS/${jobsDirName}/"
mv "/tmp/meta_upload_init_${datedArchiveName}.json" "/opt/aws-glacier-backup/COMPLETED_JOBS/${jobsDirName}/"

printf "\nDeleting archive and split parts.\n"
rm -f /tmp/${datedArchiveName}
rm -f /tmp/${datedArchiveName}.*
printf "\nClean up complete!\n"

}

###########################
# FUNCTION CALLS AND LOGIC
###########################

create_archive
encrypt_archive
compute_treehash

# Single or multi-part upload?

printf "\nArchive Size: ${archiveSize}\n Chunk Size: ${chunkSize}\n"

if [[ ${archiveSize} -lt ${chunkSize} ]]; then
        upload_single
else
        # Split archive
        split_archive

        # Caculate range necessary to complete multipart upload
        calculate_range

        # Array initialization for $partNum sequence in multipart upload
        init_array

        # Begin multipart upload
        upload_multipart
fi

# See if valid archiveId was generated, otherwise try to abort the upload
check_upload

# Clean up
clean_up

exit 0