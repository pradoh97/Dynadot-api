#!/bin/bash
# Extract Main Domain (assumes standard structure like example.com)
# NOTE: If using a double TLD like .co.uk, change -f1-2 to -f1-3 below
domain=$(echo "$CERTBOT_DOMAIN" | rev | cut -d. -f1-2 | rev)

# Extract Subdomain
if [ "$CERTBOT_DOMAIN" == "$domain" ]; then
    # It is a root domain (example.com), so subdomain is empty
    subdomain=""
else
    # It is a subdomain (www.example.com), remove the domain part
    subdomain=${CERTBOT_DOMAIN%.$domain}
fi

scriptDir=$(dirname $0)

apiKey=$(cat "$scriptDir/apikey")
apiUrl="https://api.dynadot.com/api3.json"

#Response of the get_dns and set_dns2 methods from Dynadot API
getResponseFile="$scriptDir/getResponse.xml"
setResponseFile="$scriptDir/setResponse.xml"

logFile="$scriptDir/logfile.log"
domainNodes="/GetDnsResponse/GetDnsContent/NameServerSettings"
maindomainNodes="$domainNodes/MainDomains"
subdomainNodes="$domainNodes/SubDomains"

# Initialize empty string for storing the previous main domain records in API-call format
mainRecords=""

# Initialize empty string for storing the subdomain records in API-call format
subRecords=""

# Control flag to check if the record already exists:
# 0: did not exist
# 1: did exist
recordExists=0

# Control flag to check if the record already exists and needs to be changed:
# 0: did not change
# 1: did change
recordChanged=0

# Dynadot index for the record to be modified or created
recordIndex=0

# Index for the last record
lastRecordIndex=0

#The subdomain key in dynadot
if [ -z "$subdomain" ] || [ "$subdomain" == "*" ]; then
    newRecord="_acme-challenge"
else
    newRecord="_acme-challenge.$subdomain"
fi

###
# Writes to a log file ($logFile), by default it writes <hh:mm:ss message>.
# $1 the <message> to be writen
#
# $2: set it to 1 to include the day, month and year before hh:mm:ss
# omit or use any other value to keep the default format.
function writeLog(){
  if [ ! -z $2 ] && [ $2 -eq 1 ]; then
    # Output includes the day, month and year
    echo "[$(date +'%D %H:%M:%S')] $1" >> $logFile
  else
    echo "[$(date +'%H:%M:%S')] $1" >> $logFile
  fi
}
writeLog '----------Begin log----------' 1
writeLog "Will attempt creating $newRecord for $domain with value $CERTBOT_VALIDATION"

#Installs libxml2-utils and jq
function installPrereqs(){
  libxmlInstalled=$(apt -qq list libxml2-utils 2>/dev/null | grep "instal")
  jqInstalled=$(apt -qq list jq 2>/dev/null | grep "instal")
  curlInstalled=$(apt -qq list curl 2>/dev/null | grep "instal")
  
  if [[ ! -n $curlInstalled ]]; then
    writeLog "Installing curl"
    apt install curl -y
  fi
  if [[ ! -n $libxmlInstalled ]]; then
    writeLog "Installing libxml2-utils"
    apt install libxml2-utils -y
  fi

  if [[ ! -n $jqInstalled ]]; then
    writeLog "Installing jq"
    apt install jq -y
  fi
  }

#Get dns current settings
function getCurrentDNSSetings(){
  curl -s -o $getResponseFile "https://api.dynadot.com/api3.xml?key=${apiKey}&command=get_dns&domain=${domain}"

  #Check if response is valid
  responseCode="$(echo "cat /GetDnsResponse/GetDnsHeader/ResponseCode/text()" | xmllint --nocdata --shell ${getResponseFile} | sed '1d;$d')"
  if [ "$responseCode" -ne 0 ]; then
      writeLog "Error: Response Code $responseCode"

      #Api keys from dynadot are 42 chars long
      if [ ${#apiKey} -lt 42 ];then
        writeLog "The API key should be 42 characters long, this one is ${#apiKey}"
      fi

      exit 1
  fi
}

# Create a string with the API-call format of the main records from the current config.
function formatMainRecords(){
  mainEntriesCount="$(xmllint --xpath "count($maindomainNodes/*)" $getResponseFile)"

  # Iterate through main domain records
  index=0
  while [ $index -lt "$mainEntriesCount" ]; do

      # XML-nodes index starts at 1
      xmlIndex=$index+1

      # Read and store the type of the current main record
      type="$(echo "cat $maindomainNodes/MainDomainRecord[$xmlIndex]/RecordType/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"

      # Make the type lowercase and removes trailing or leading spaces
      type=${type,,}
      type=$(echo "$type" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

      # Read and store the value of the current main record
      value="$(echo "cat $maindomainNodes/MainDomainRecord[$xmlIndex]/Value/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"

      # Encode special chars for parameters
      value=$(jq -rn --arg x "$value" '$x|@uri')

      # Reformat the received data into the needed API-format and append it to the mainRecords variable
      if [[ $type == "mx" ]]; then

        value2="$(echo "cat $maindomainNodes/MainDomainRecord[$xmlIndex]/Value2/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"
        value2=$(jq -rn --arg x "$value2" '$x|@uri')

        mainRecords+="&main_record_type$index=$type&main_record$index=$value&main_recordx$index=$value2"

      else
        mainRecords+="&main_record_type$index=$type&main_record$index=$value"
      fi

      ((index++))
  done
}

function formatSubRecords(){
  subEntriesCount="$(xmllint --xpath "count($subdomainNodes/*)" $getResponseFile)"

  # Iterate through subdomain records
  index=0
  while [ $index -le "$subEntriesCount" ]; do

      # IMPORTANT: The XML-nodes index starts at 1!
      xmlIndex=$index+1

      subhost="$(echo "cat $subdomainNodes/SubDomainRecord[$xmlIndex]/Subhost/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"
      type="$(echo "cat $subdomainNodes/SubDomainRecord[$xmlIndex]/RecordType/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"

      #Makes the type lowercase and removes trailing or leading spaces
      type=${type,,}
      type=$(echo "$type" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      
      value="$(echo "cat $subdomainNodes/SubDomainRecord[$xmlIndex]/Value/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"

      if [ -n "$type" ]; then
        # Check if the record exists and replace the current value.
        if [ "$subhost" = $newRecord ] && [ $type == "txt" ]; then
            # Set the flag to indicate that the record exists
            recordExists=1

            if [ $value != "$CERTBOT_VALIDATION" ]; then
              # Overwrite the value that is stored in the TXT-record to the needed challenge key
              value="$CERTBOT_VALIDATION"

              # Unset flag to indicate that a record was indeed changed
              recordChanged=1
              recordIndex=$index
            fi
            echo "Found"
        fi

        # Encode special chars for parameters
        value=$(jq -rn --arg x "$value" '$x|@uri')

        # Reformat the received data into the needed API-format and append it to the subRecords variable
        if [[ $type == "mx" ]]; then
          value2="$(echo "cat $subdomainNodes/SubDomainRecord[$xmlIndex]/Value2/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"
          value2=$(jq -rn --arg x "$value2" '$x|@uri')

          subRecords+="&subdomain$index=$subhost&sub_record_type$index=$type&sub_record$index=$value&sub_recordx$index=$value2"
        else
          subRecords+="&subdomain$index=$subhost&sub_record_type$index=$type&sub_record$index=$value"
        fi
      fi

      lastRecordIndex=$index
      ((index++))
  done
}

# Returns 1 if there are changes to be pushed via set_dns2 API call.
# Returns 0 if no changes are needed (does not do an API call)
function changesIntroduced(){
  doChanges=0

  if [ $recordExists -eq 0 ]; then
    doChanges=1
    recordIndex=$lastRecordIndex
    writeLog "Challenge record $newRecord not found."
    writeLog "Will create $newRecord on index $recordIndex with value $CERTBOT_VALIDATION."
  fi
  if [ $recordChanged -eq 1 ]; then
    doChanges=1
    writeLog "Challenge record $newRecord found."
    writeLog "Will replace $newRecord value, on index $recordIndex, with $CERTBOT_VALIDATION."
  fi
  subRecords+="&subdomain$recordIndex=$newRecord&sub_record_type$recordIndex=txt&sub_record$recordIndex=$CERTBOT_VALIDATION"
}

installPrereqs
getCurrentDNSSetings
formatMainRecords
formatSubRecords
changesIntroduced

if [ $doChanges -eq 1 ]; then
  # Combine everything into one api command/request
  apiRequest="key=$apiKey&command=set_dns2&domain=$domain$mainRecords$subRecords"
  # Combine api-url and -request into the finished command
  fullRequest="$apiUrl?$apiRequest"
  curl -s "$fullRequest" > $setResponseFile

  # For DNS propagation
  sleep 60
fi
