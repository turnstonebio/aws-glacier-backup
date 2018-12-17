# AWS Glacier Backup

## Description
Shell script for creating, encrypting, splitting and pushing archives to AWS Glacier.

This will create a directory at __/opt/aws-glacier-backup/COMPLETED_JOBS__ with the name of your archive concatenated with the date and time.
Inside will be a manifest of all files in the archive and two json files with Glacier related metadata.

## Prerequisites

##### jq
https://stedolan.github.io/jq/

##### treehash
https://github.com/jdswinbank/treehash

##### PyPi
https://pypi.org/

##### AWS CLI
https://aws.amazon.com/cli/

##### GnuPG
https://www.gnupg.org/

##### bc
https://www.gnu.org/software/bc/

## Variables

|Variable|Description|Default Value|
|--------|-----------|-------------|
|_sourceDir_|Base directory|none|
|_archiveDir_|Directory containing items to be archived|none|
|_dateArchiveName_|Name of created tar.gz archive concatenated from archiveDir and the current date|none|
|_chunkSize_|Largest allowable single object size for AWS Glacier|4294967296|
|_chunkSizeGiB_|Calculated size of $chunkSize in gibibytes|$chunkSize/1073741824|
|_chunkSizeMiB_|Calculated size of $chunkSize in mibibytes|$chunkSize/1048576|
|_archiveSize_|Resultant size of encrypted tar.gz archive|none|
|_vaultName_|Name of AWS Glacier vault where uploads will be targeted|none|
|_gpgRecipient_|Valid email or key id that the archive will be encrypted with|none|
|_TREEHASH_|Calculated SHA256 tree hash for validating upload parts |none|
|_UPLOADID_|AWS Glacier upload ID returned as a json value|none|
|_ARCHIVEID_|AWS Glacier archive ID returned as a json value|none|
|_ARCHIVEID_LEN_|Character length of ARCHIVEID; valid ARCHIVEID is 138 characters long|none|

There are some other variables, but they are used for mundane stuff like calculating ranges.

## Syntax
./**aws-glacier-backup.sh** _/source/directory/path target_directory_

## Example
**./aws-glacier-backup.sh** /mnt/freenas/projects VisioDrawings

will create the following files:

|Archive|Manifest|JSON|
|-------|--------|----|
|VisioDrawings_03-20-2018_1215.tar.gz|manifest_VisioDrawings_03-20-2018_1215.txt|meta_upload_init_VisioDrawings_03-20-2018_1215.json<br>meta_upload_complete_VisioDrawings_03-20-2018_1215.json|

The archive will be uploaded to Glacier and deleted locally.  The manifest and json files are stored in **/opt/aws-glacier-backup/COMPLETED_JOBS/VisioDrawing_03-20-2018_1215**)

## Written By
David Hunter, 2018