#!/bin/bash
#includes TLD: example.com
domain=$(expr match "$CERTBOT_DOMAIN" '.*\.\(.*\..*\)')

#Extracts a subdomain, for www.example.com it would extract www
subdomain=$(expr match "$CERTBOT_DOMAIN" '\(.*\)\..*\..*')

apiKey=$(cat ./apikey)
apiUrl="https://api.dynadot.com/api3.json"

#Response of the get_dns and set_dns2 methods from Dynadot API
getResponseFile="./getResponse.xml"
setResponseFile="./setResponse.xml"

logFile="./logfile.log"
domainNodes="/GetDnsResponse/GetDnsContent/NameServerSettings"
maindomainNodes="$domainNodes/MainDomains"
subdomainNodes="$domainNodes/SubDomains"

#The subdomain key in dynadot
newRecord="_acme-challenge.$subdomain"
[[ "${subdomain}" == '*' ]]  && newRecord="_acme-challenge"

###
# Writes to a log file ($logFile), by default it writes <hh:mm:ss message>.
# $1 the <message> to be writen
#
# $2: set it to 1 to include the day, month and year before hh:mm:ss
# omit or use any other value to keep the default format.
function writeLog(){
  if [ $2 == 1 ]; then
    #Output includes the day, month and year
    echo "[$(date +'%D %H:%M:%S')] $1" >> $logFile
  else
    echo "[$(date +'%H:%M:%S')] $1" >> $logFile
  fi
}

writeLog '----------Begin log----------' 1
writeLog "Will attempt creating $newRecord for $domain with value $CERTBOT_VALIDATION"

#Installs libxml2-utils and jq
function install-prereqs(){
  libxmlInstalled=$(apt -qq list libxml2-utils 2>/dev/null | grep "instal")
  jqInstalled=$(apt -qq list jq 2>/dev/null | grep "instal")
  
  if [[ ! -n $libxmlInstalled ]]; then
    writeLog "Installing libxml2-utils"
    apt install libxml2-utils -y
  fi

  if [[ ! -n $jqInstalled ]]; then
    writeLog "Installing jq"
    apt install jq -y
  fi
}

install-prereqs

#Get dns current settings
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

mainEntriesCount="$(xmllint --xpath "count($maindomainNodes/*)" $getResponseFile)"

# Initialize empty string for storing the previous main domain records in API-call format
mainRecords=""

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

subEntriesCount="$(xmllint --xpath "count($subdomainNodes/*)" $getResponseFile)"

# Initialize empty string for storing the subdomain records in API-call format
subRecords=""

# Control flag to check if any records where actually changed
unchanged=1

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
          # Overwrite the value that is stored in the TXT-record to the needed challenge key
          value=$CERTBOT_VALIDATION

          # Unset flag to indicate that a record was indeed changed
          unchanged=0
          echo "Found"
      fi

      # Encode special chars for parameters
      value=$(jq -rn --arg x "$value" '$x|@uri')

      # Reformat the received data into the needed API-format and append it to the subRecords variable
      if [[ $type == "mx" ]]; then
        value2="$(echo "cat $subdomainNodes/SubDomainRecord[$xmlIndex]/Value2/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"
        value2=$(jq -rn --arg x "$value2" '$x|@uri')

        subRecords+="&subdomain$index=$subhost&sub_record_type$index=$type&sub_record$index=$value&sub_recordx$index=$value"
      else
        subRecords+="&subdomain$index=$subhost&sub_record_type$index=$type&sub_record$index=$value"
      fi
    fi
    
    ((index++))
done

# Create the record if it does not exist
if [ $unchanged -eq 1 ]; then
    index=$(($index - 1))
    writeLog "Challenge record $newRecord not found."
    writeLog "Will create $newRecord on index $index with value $CERTBOT_VALIDATION."

    subRecords+="&subdomain$index=$newRecord&sub_record_type$index=txt&sub_record$index=$CERTBOT_VALIDATION"
fi

# Combine everything into one api command/request
apiRequest="key=$apiKey&command=set_dns2&domain=$domain$mainRecords$subRecords"

# Combine api-url and -request into the finished command
fullRequest="$apiUrl?$apiRequest"
curl -s "$fullRequest" > $setResponseFile

# For DNS propagation
sleep 60
