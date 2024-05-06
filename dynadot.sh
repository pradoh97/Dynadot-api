#!/bin/bash

#This file would be the manual auth hook script for certbot

#includes TLD: example.com
domain=$(expr match "$CERTBOT_DOMAIN" '.*\.\(.*\..*\)')

#Extracts a subdomain, for www.example.com it would extract www
subdomain=$(expr match "$CERTBOT_DOMAIN" '\(.*\)\..*\..*')

apiKey=$(cat ./apikey)
apiUrl="https://api.dynadot.com/api3.json"
getResponseFile="/tmp/apiResponse.xml"
logFile="/tmp/logfile.log"
maindomainNodes="/GetDnsResponse/GetDnsContent/NameServerSettings/MainDomains"
subdomainNodes="/GetDnsResponse/GetDnsContent/NameServerSettings/SubDomains"

newRecord="_acme-challenge.$subdomain"
[[ "${subdomain}" == '*' ]]  && newRecord="_acme-challenge"

echo '----------Begin log----------' >> $logFile
echo "Subdomain: $subdomain" >> $logFile
echo "Domain: $domain" >> $logFile
echo "Certbot_domain: $CERTBOT_DOMAIN" >> $logFile
echo "Certbot_validation: $CERTBOT_VALIDATION" >> $logFile

#Installs libxml2-utils
function install-libxml(){
  libxmlInstalled=$(apt -qq list libxml2-utils 2>/dev/null | grep "instal")
  if [[ ! -n $libxmlInstalled ]]; then
    apt install libxml2-utils -y
  fi
}

#Get dns settings
curl -s -o $getResponseFile "https://api.dynadot.com/api3.xml?key=${apiKey}&command=get_dns&domain=${domain}"

#Check if response is valid
responseCode="$(echo "cat /GetDnsResponse/GetDnsHeader/ResponseCode/text()" | xmllint --nocdata --shell ${getResponseFile} | sed '1d;$d')"
if [ "$responseCode" -ne 0 ]; then
    echo "Error: Response Code not 0, was $responseCode instead!" >> $logFile
    exit 1
fi

mainEntriesCount="$(xmllint --xpath "count($maindomainNodes/*)" $getResponseFile)"

# Initialize empty string for storing the previous main domain records in API-call format
mainRecords=""

# Iterate through main domain records
index=0
while [ $index -lt "$mainEntriesCount" ]; do

    # IMPORTANT: The XML-nodes index starts at 1!
    xmlIndex=$index+1

    # Read and store the type of the current main record
    type="$(echo "cat $maindomainNodes/MainDomainRecord[$xmlIndex]/RecordType/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"
    
    #Makes the type lowercase and removes trailing or leading spaces
    type=${type,,}
    type=$(echo "$type" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Read and store the value of the current main record
    value="$(echo "cat $maindomainNodes/MainDomainRecord[$xmlIndex]/Value/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"
    
    #Encodes special chars for parameters
    value=$(jq -rn --arg x "$value" '$x|@uri')
    value2=$(jq -rn --arg x "$value2" '$x|@uri')

    # Reformat the received data into the needed API-format and append it to the mainRecords variable
    if [[ $type == "mx" ]]; then
      value2="$(echo "cat $maindomainNodes/MainDomainRecord[$xmlIndex]/Value2/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"
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
        value2="$(echo "cat $subdomainNodes/SubDomainRecord[$xmlIndex]/Value2/text()" | xmllint --nocdata --shell $getResponseFile | sed '1d;$d')"
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
    echo "Error: Challenge Node $newRecord not found, no changes to DNS-record performed!" >> $logFile
    echo "Will create $newRecord on index $index with value $CERTBOT_VALIDATION" >> $logFile

    subRecords+="&subdomain$index=$newRecord&sub_record_type$index=txt&sub_record$index=$CERTBOT_VALIDATION"
    #exit 2
fi

#Replaced, ansible playbook installs it
#install-libxml

# Combine everything into one api command/request
apiRequest="key=$apiKey&command=set_dns2&domain=$domain$mainRecords$subRecords"

# Combine api-url and -request into the finished command
fullRequest="$apiUrl?$apiRequest"
curl -s "$fullRequest" > $getResponseFile
sleep 60
