#!/bin/bash
#includes TLD: example.com
domain=$(expr match "$CERTBOT_DOMAIN" '.*\.\(.*\..*\)')

#Extracts a subdomain, for www.example.com it would extract www
subdomain=$(expr match "$CERTBOT_DOMAIN" '\(.*\)\..*\..*')

apiKey=$(cat ./apikey)
apiUrl="https://api.dynadot.com/api3.json"
responseFile="./apiResponse.xml"
logFile="./logfile.log"
domainNodes="/GetDnsResponse/GetDnsContent/NameServerSettings"
maindomainNodes="$domainNodes/MainDomains"
subdomainNodes="$domainNodes/SubDomains"

#The subdomain key in dynadot
newRecord="_acme-challenge.$subdomain"
[[ "${subdomain}" == '*' ]]  && newRecord="_acme-challenge"

function writeLog(){
  echo "[$(date +'%H:%M:%S')] $1" >> $logFile
}

writeLog '----------Begin log----------'
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

#Get dns settings
curl -s -o $responseFile "https://api.dynadot.com/api3.xml?key=${apiKey}&command=get_dns&domain=${domain}"

#Check if response is valid
responseCode="$(echo "cat /GetDnsResponse/GetDnsHeader/ResponseCode/text()" | xmllint --nocdata --shell ${responseFile} | sed '1d;$d')"
if [ "$responseCode" -ne 0 ]; then
    writeLog "Error: Response Code not 0, was $responseCode instead!"
    exit 1
fi

mainEntriesCount="$(xmllint --xpath "count($maindomainNodes/*)" $responseFile)"

# Initialize empty string for storing the previous main domain records in API-call format
mainRecords=""

# Iterate through main domain records
index=0
while [ $index -lt "$mainEntriesCount" ]; do

    # IMPORTANT: The XML-nodes index starts at 1!
    xmlIndex=$index+1

    # Read and store the type of the current main record
    type="$(echo "cat $maindomainNodes/MainDomainRecord[$xmlIndex]/RecordType/text()" | xmllint --nocdata --shell $responseFile | sed '1d;$d')"
    
    #Makes the type lowercase and removes trailing or leading spaces
    type=${type,,}
    type=$(echo "$type" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Read and store the value of the current main record
    value="$(echo "cat $maindomainNodes/MainDomainRecord[$xmlIndex]/Value/text()" | xmllint --nocdata --shell $responseFile | sed '1d;$d')"
    
    #Encodes special chars for parameters
    value=$(jq -rn --arg x "$value" '$x|@uri')
    value2=$(jq -rn --arg x "$value2" '$x|@uri')

    # Reformat the received data into the needed API-format and append it to the mainRecords variable
    if [[ $type == "mx" ]]; then
      value2="$(echo "cat $maindomainNodes/MainDomainRecord[$xmlIndex]/Value2/text()" | xmllint --nocdata --shell $responseFile | sed '1d;$d')"
      mainRecords+="&main_record_type$index=$type&main_record$index=$value&main_recordx$index=$value2"
    else
      mainRecords+="&main_record_type$index=$type&main_record$index=$value"
    fi

    ((index++))
done

subEntriesCount="$(xmllint --xpath "count($subdomainNodes/*)" $responseFile)"

# Initialize empty string for storing the subdomain records in API-call format
subRecords=""

# Control flag to check if any records where actually changed
unchanged=1

# Iterate through subdomain records
index=0
while [ $index -le "$subEntriesCount" ]; do

    # IMPORTANT: The XML-nodes index starts at 1!
    xmlIndex=$index+1

    subhost="$(echo "cat $subdomainNodes/SubDomainRecord[$xmlIndex]/Subhost/text()" | xmllint --nocdata --shell $responseFile | sed '1d;$d')"
    type="$(echo "cat $subdomainNodes/SubDomainRecord[$xmlIndex]/RecordType/text()" | xmllint --nocdata --shell $responseFile | sed '1d;$d')"
    
    #Makes the type lowercase and removes trailing or leading spaces
    type=${type,,}
    type=$(echo "$type" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    value="$(echo "cat $subdomainNodes/SubDomainRecord[$xmlIndex]/Value/text()" | xmllint --nocdata --shell $responseFile | sed '1d;$d')"

    if [ -n "$type" ]; then
      # Check if the subdomain of the current record is the one that needs to be changed
      if [ "$subhost" = $newRecord ] && [ $type == "txt" ]; then
          # Overwrite the value that is stored in the TXT-record to the needed challenge key
          value=$CERTBOT_VALIDATION

          # Unset flag to indicate that a record was indeed changed
          unchanged=0
          echo "Found"
      fi

      #Encodes special chars for parameters
      value=$(jq -rn --arg x "$value" '$x|@uri')
      value2=$(jq -rn --arg x "$value2" '$x|@uri')

      # Reformat the received data into the needed API-format and append it to the subRecords variable
      if [[ $type == "mx" ]]; then
        value2="$(echo "cat $subdomainNodes/SubDomainRecord[$xmlIndex]/Value2/text()" | xmllint --nocdata --shell $responseFile | sed '1d;$d')"
        subRecords+="&subdomain$index=$subhost&sub_record_type$index=$type&sub_record$index=$value&sub_recordx$index=$value"
      else
        subRecords+="&subdomain$index=$subhost&sub_record_type$index=$type&sub_record$index=$value"
      fi
    fi
    
    ((index++))
done
# Throw error and abort if no records where changed
if [ $unchanged -eq 1 ]; then
    index=$(($index - 1))
    writeLog "Error: Challenge Node $newRecord not found, no changes to DNS-record performed!"
    writeLog "Will create $newRecord on index $index with value $CERTBOT_VALIDATION"

    subRecords+="&subdomain$index=$newRecord&sub_record_type$index=txt&sub_record$index=$CERTBOT_VALIDATION"
    #exit 2
fi

#Replaced, ansible playbook installs it
install-prereqs

# Combine everything into one api command/request
apiRequest="key=$apiKey&command=set_dns2&domain=$domain$mainRecords$subRecords"

# Combine api-url and -request into the finished command
fullRequest="$apiUrl?$apiRequest"
curl -s "$fullRequest" > $responseFile
sleep 60
