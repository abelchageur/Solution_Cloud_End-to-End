#!/bin/bash

# Variables
resourceGroup="mabelchaguer"
location="eastus"
dateSuffix=$(date +%Y%m%d)
namespaceName="MyEventHubsNamespace-$dateSuffix"
eventHubName="CustomerReviewsHub-$dateSuffix"
policyName="SendPolicy"
storageAccountName="mystorage$dateSuffix"
functionAppName="MyFunctionApp-$dateSuffix"
cognitiveServiceName="MyCognitiveService-$dateSuffix"
cosmosAccountName="mycosmosdb$dateSuffix"
cosmosDbName="ReviewsDB"
cosmosContainerName="Reviews"
logicAppName="MyLogicApp-$dateSuffix"
functionAppDir="MyFunctionApp"

# Ensure unique names
storageAccountName=$(echo $storageAccountName | tr -d '-')
cosmosAccountName=$(echo $cosmosAccountName | tr -d '-')

# Check if Azure Functions Core Tools are installed
if ! command -v func &> /dev/null; then
    echo "Azure Functions Core Tools not found. Installing..."
    if ! command -v npm &> /dev/null; then
        echo "Error: npm is required to install Azure Functions Core Tools. Please install Node.js and npm."
        exit 1
    fi
    sudo npm install -g azure-functions-core-tools@4 --unsafe-perm true
    if ! command -v func &> /dev/null; then
        echo "Error: Failed to install Azure Functions Core Tools. Please install manually."
        exit 1
    fi
fi

# Check if Function App directory exists
if [ ! -d "$functionAppDir" ]; then
    echo "Error: Function App directory $functionAppDir does not exist. Please create it with the Function App code."
    exit 1
fi

# Check provider registration status
echo "Checking resource provider registration..."
for provider in Microsoft.CognitiveServices Microsoft.DocumentDB Microsoft.Logic; do
    status=$(az provider show --namespace $provider --query registrationState -o tsv)
    if [ "$status" != "Registered" ]; then
        echo "Warning: $provider is not registered (status: $status). Attempting to register..."
        az provider register --namespace $provider || echo "Failed to register $provider. You may need higher permissions."
    else
        echo "$provider is already registered."
    fi
done

# Wait for provider registration (if attempted)
echo "Waiting for provider registration to complete (if any)..."
for provider in Microsoft.CognitiveServices Microsoft.DocumentDB Microsoft.Logic; do
    status=$(az provider show --namespace $provider --query registrationState -o tsv)
    if [ "$status" != "Registered" ]; then
        echo "Waiting for $provider registration..."
        for i in {1..10}; do
            status=$(az provider show --namespace $provider --query registrationState -o tsv)
            if [ "$status" == "Registered" ]; then
                break
            fi
            sleep 30
        done
        if [ "$status" != "Registered" ]; then
            echo "Warning: $provider registration failed or timed out. Proceeding, but some resources may fail."
        fi
    fi
done

# Delete existing resources
echo "Deleting existing resources if they exist..."
az eventhubs namespace delete --resource-group $resourceGroup --name $namespaceName || echo "Namespace $namespaceName does not exist."
az storage account delete --resource-group $resourceGroup --name $storageAccountName --yes || echo "Storage Account $storageAccountName does not exist."
az functionapp delete --resource-group $resourceGroup --name $functionAppName || echo "Function App $functionAppName does not exist."
az cognitiveservices account delete --resource-group $resourceGroup --name $cognitiveServiceName || echo "Cognitive Service $cognitiveServiceName does not exist."
az cosmosdb delete --resource-group $resourceGroup --name $cosmosAccountName --yes || echo "Cosmos DB $cosmosAccountName does not exist."
az logicapp delete --resource-group $resourceGroup --name $logicAppName || echo "Logic App $logicAppName does not exist."

# Create Event Hubs Namespace
echo "Creating Event Hubs Namespace: $namespaceName..."
az eventhubs namespace create --resource-group $resourceGroup --name $namespaceName --location $location --sku Standard || {
    echo "Failed to create Event Hubs Namespace. Exiting."
    exit 1
}

# Create Event Hub
echo "Creating Event Hub: $eventHubName..."
az eventhubs eventhub create --resource-group $resourceGroup --namespace-name $namespaceName --name $eventHubName --partition-count 4 || {
    echo "Failed to create Event Hub. Exiting."
    exit 1
}

# Create Shared Access Policy
echo "Creating Shared Access Policy: $policyName..."
az eventhubs eventhub authorization-rule create --resource-group $resourceGroup --namespace-name $namespaceName --eventhub-name $eventHubName --name $policyName --rights Send || {
    echo "Failed to create Shared Access Policy. Exiting."
    exit 1
}

# Get Event Hubs Connection String
echo "Retrieving Event Hubs connection string..."
eventHubConnectionString=$(az eventhubs eventhub authorization-rule keys list --resource-group $resourceGroup --namespace-name $namespaceName --eventhub-name $eventHubName --name $policyName --query "primaryConnectionString" --output tsv)
if [ -z "$eventHubConnectionString" ]; then
    echo "Failed to retrieve Event Hubs connection string. Exiting."
    exit 1
fi
echo "Event Hubs Connection String: $eventHubConnectionString"

# Create Storage Account
echo "Creating Storage Account: $storageAccountName..."
az storage account create --resource-group $resourceGroup --name $storageAccountName --location $location --sku Standard_LRS || {
    echo "Failed to create Storage Account. Exiting."
    exit 1
}

# Create Function App
echo "Creating Function App: $functionAppName..."
az functionapp create --resource-group $resourceGroup --name $functionAppName --storage-account $storageAccountName --consumption-plan-location $location --runtime python --runtime-version 3.12 --functions-version 4 --os-type Linux || {
    echo "Failed to create Function App. Exiting."
    exit 1
}

# Create Cognitive Services (try F0 SKU to avoid quota issues)
echo "Creating Cognitive Services: $cognitiveServiceName..."
az cognitiveservices account create --resource-group $resourceGroup --name $cognitiveServiceName --location $location --kind TextAnalytics --sku F0 || {
    echo "Failed to create Cognitive Services with F0 SKU. Trying S0 SKU..."
    az cognitiveservices account create --resource-group $resourceGroup --name $cognitiveServiceName --location $location --kind TextAnalytics --sku S0 || {
        echo "Failed to create Cognitive Services with S0 SKU. Skipping Cognitive Services setup."
        cognitiveKey=""
        cognitiveEndpoint=""
    }
}

# Get Cognitive Services Key and Endpoint (if created)
if [ -n "$cognitiveServiceName" ]; then
    echo "Retrieving Cognitive Services key and endpoint..."
    cognitiveKey=$(az cognitiveservices account keys list --resource-group $resourceGroup --name $cognitiveServiceName --query "key1" --output tsv 2>/dev/null)
    cognitiveEndpoint=$(az cognitiveservices account show --resource-group $resourceGroup --name $cognitiveServiceName --query "properties.endpoint" --output tsv 2>/dev/null)
    echo "Cognitive Services Key: $cognitiveKey"
    echo "Cognitive Services Endpoint: $cognitiveEndpoint"
fi

# Create Cosmos DB Account
echo "Creating Cosmos DB Account: $cosmosAccountName..."
az cosmosdb create --resource-group $resourceGroup --name $cosmosAccountName --locations regionName=$location || {
    echo "Failed to create Cosmos DB Account. Exiting."
    exit 1
}

# Create Cosmos DB Database
echo "Creating Cosmos DB Database: $cosmosDbName..."
az cosmosdb sql database create --resource-group $resourceGroup --account-name $cosmosAccountName --name $cosmosDbName || {
    echo "Failed to create Cosmos DB Database. Exiting."
    exit 1
}

# Create Cosmos DB Container
echo "Creating Cosmos DB Container: $cosmosContainerName..."
az cosmosdb sql container create --resource-group $resourceGroup --account-name $cosmosAccountName --database-name $cosmosDbName --name $cosmosContainerName --partition-key-path "/id" || {
    echo "Failed to create Cosmos DB Container. Exiting."
    exit 1
}

# Get Cosmos DB Connection String and Key
echo "Retrieving Cosmos DB connection string and key..."
cosmosConnectionString=$(az cosmosdb keys list --resource-group $resourceGroup --name $cosmosAccountName --type connection-strings --query "connectionStrings[0].connectionString" --output tsv)
cosmosKey=$(az cosmosdb keys list --resource-group $resourceGroup --name $cosmosAccountName --query primaryMasterKey -o tsv)
if [ -z "$cosmosConnectionString" ] || [ -z "$cosmosKey" ]; then
    echo "Failed to retrieve Cosmos DB connection string or key. Exiting."
    exit 1
fi
echo "Cosmos DB Connection String: $cosmosConnectionString"

# Create Logic App
echo "Creating Logic App: $logicAppName..."
az resource create --resource-group $resourceGroup --resource-type Microsoft.Logic/workflows --name $logicAppName --location $location --properties '{}' || {
    echo "Failed to create Logic App. Exiting."
    exit 1
}

# Configure Function App environment variables
echo "Configuring Function App environment variables..."
az functionapp config appsettings set \
  --resource-group $resourceGroup \
  --name $functionAppName \
  --settings "EVENT_HUB_CONNECTION_STR=$eventHubConnectionString" || {
    echo "Failed to set EVENT_HUB_CONNECTION_STR. Continuing."
}
az functionapp config appsettings set \
  --resource-group $resourceGroup \
  --name $functionAppName \
  --settings "COGNITIVE_ENDPOINT=$cognitiveEndpoint" || {
    echo "Failed to set COGNITIVE_ENDPOINT. Continuing."
}
az functionapp config appsettings set \
  --resource-group $resourceGroup \
  --name $functionAppName \
  --settings "COGNITIVE_KEY=$cognitiveKey" || {
    echo "Failed to set COGNITIVE_KEY. Continuing."
}
az functionapp config appsettings set \
  --resource-group $resourceGroup \
  --name $functionAppName \
  --settings "COSMOS_ENDPOINT=$cosmosConnectionString" || {
    echo "Failed to set COSMOS_ENDPOINT. Continuing."
}
az functionapp config appsettings set \
  --resource-group $resourceGroup \
  --name $functionAppName \
  --settings "COSMOS_KEY=$cosmosKey" || {
    echo "Failed to set COSMOS_KEY. Continuing."
}

# Deploy Function App
echo "Deploying Function App: $functionAppName..."
cd $functionAppDir
pip install -r requirements.txt || {
    echo "Failed to install Python dependencies. Exiting."
    exit 1
}
func azure functionapp publish $functionAppName --python || {
    echo "Failed to deploy Function App. Exiting."
    exit 1
}
cd ..

 rampart.js
# Output connection details
echo "Setup complete! Connection details:"
echo "Event Hubs Connection String: $eventHubConnectionString"
echo "Storage Account Name: $storageAccountName"
echo "Function App Name: $functionAppName"
echo "Cognitive Services Key: $cognitiveKey"
echo "Cognitive Services Endpoint: $cognitiveEndpoint"
echo "Cosmos DB Connection String: $cosmosConnectionString"
echo "Logic App Name: $logicAppName"

echo "Next steps:"
echo "1. Update SendSlackNotification/__init__.py with your Slack webhook URL or set SLACK_WEBHOOK_URL environment variable."
echo "2. Configure the Logic App workflow in the Azure Portal to monitor Cosmos DB and trigger SendSlackNotification for negative reviews."
echo "3. Set up Power BI to connect to Cosmos DB for visualization."
echo "4. Update generate_reviews.py with EVENT_HUB_CONNECTION_STR and EVENT_HUB_NAME, then run it to start generating reviews."
