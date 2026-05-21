#!/bin/bash
set -e

####################################################
# This script manages the buiding of a debian package that will be used
# to install secrets necessary for the operation of the Everclean data pipeline.
# Since the database schema is stored in github, but we don't to commit
# passwords there, all database passwords are stored in Azure; this package will:
# - Authenticate to Azure via CLI
# - Download secrets and package them into a debian
# - Configure a postinst script to execute each downloaded .sql file
# - Remove all downloaded .sql files
#
# The build infrastructure for this package is slightly different in the
# context of docker container builds triggered by the Jenkins pipeline.
# For such a container build, the process is:
# - Locate secrets downloaded by Jenkins and package them into a debian
# - Configure a postinst script to execute each downloaded .sql file
# - Remove all downloaded .sql files
#
# In either case, this build script will provide values for these variables:
# - FDW_AUTH_SQL
# - TOPSIDE_DB_AUTH_SQL
# These locations will be used by CMakeLists.txt to perform the necessary steps
# for the proper build.
####################################################

# Paths
PROJECT_ROOT="$(dirname "$0")"
BUILD_DIR="$PROJECT_ROOT/build"
SECRET_LOCATION="$BUILD_DIR"

# Local variable to control docker build cases
# Using ON/OFF since it meshes well with cmake syntax
CONTAINER_BUILD="OFF"

# Filenames of the secrets to download. These names MUST match
# the names configured in this package's Jenkinsfile. For example,
# this Jenkinsfile entry:
# ec-everclean-iq-fdw-auth:everclean_iq_fdw_auth.sql
# Will locate the Azure secret named 'ec-everclean-iq-fdw-auth',
# and download it to 'everclean_iq_fdw_auth.sql'

# .sql database setup scripts
FDW_AUTH_FILENAME="everclean_iq_fdw_auth.sql"
TOPSIDE_DB_AUTH_FILENAME="everclean_topside_db_auth.sql"

# Authentication secrets file
EC_CLEANING_AUTH_FILENAME="ec_cleaning_auth.json"
EC_CLEANING_AUTH_INSTALL_DIR="/etc/gss/keys/"

# Make sure build/ exists
mkdir -p "$BUILD_DIR"

####################################################

# Check for a docker build, ensure the Azure CLI is available
if [[ -f /.dockerenv || "$DOCKER_BUILD" == "true" ]]; then

    # Single variable for either truth, using a different name
    # so there aren't collisions with DOCKER_BUILD
    CONTAINER_BUILD="ON"
    # Use the file location provided by Jenkins
    SECRET_LOCATION="/etc/gss/keys"

    # Set the path to the files - these variables are used in
    # the cmake script (which also configures the postint.in file to use them)
    FDW_AUTH_SQL="$SECRET_LOCATION/$FDW_AUTH_FILENAME"
    TOPSIDE_DB_AUTH_SQL="$SECRET_LOCATION/$TOPSIDE_DB_AUTH_FILENAME"
    EC_CLEANING_AUTH_JSON="$SECRET_LOCATION/$EC_CLEANING_AUTH_FILENAME"

else
    # Local login
    echo "Authenticating to Azure"
    az login --tenant "11f25dfb-1f50-4b53-8068-fd44e574bd6c"

    # Set subscription explicitly - we have 'Everclean IQ' and 'Greensea'
    az account set --subscription "Everclean IQ"

    # Set the path to the files - these variables are used in
    # the cmake script (which also configures the postint.in file to use them)
    # In the case of a Jenkins build, the files will be there,
    # but a local build will need to download them to the build directory.
    FDW_AUTH_SQL="$SECRET_LOCATION/$FDW_AUTH_FILENAME"
    TOPSIDE_DB_AUTH_SQL="$SECRET_LOCATION/$TOPSIDE_DB_AUTH_FILENAME"

    # Use the Azure CLI to download the secrets
    # Foreign Data Wrapper auth
    az keyvault secret show               \
        --vault-name "kv-evercleaniq-01"  \
        --name "ec-everclean-iq-fdw-auth" \
        --query value -o tsv > "$FDW_AUTH_SQL"

    # Topside db auth
    az keyvault secret show                   \
        --vault-name "kv-evercleaniq-01"      \
        --name "ec-everclean-topside-db-auth" \
        --query value -o tsv > "$TOPSIDE_DB_AUTH_SQL"

    # Auth JSON
    # Specify the file to download to
    EC_CLEANING_AUTH_JSON="$SECRET_LOCATION/$EC_CLEANING_AUTH_FILENAME"

    # Get the JSON
    az keyvault secret show                       \
        --vault-name "kv-evercleaniq-01"          \
        --name "ec-everclean-cleaning-cx-strings" \
        --query value -o tsv > "$EC_CLEANING_AUTH_JSON"

    # Verify that the files have been downloaded and that they are not empty
    if [[ ! -s "$TOPSIDE_DB_AUTH_SQL" || ! -s "$FDW_AUTH_SQL" || ! -s "$EC_CLEANING_AUTH_JSON" ]]; then
        echo "Error: One or both required files are missing or empty:"
        echo "  $TOPSIDE_DB_AUTH_SQL"
        echo "  $FDW_AUTH_SQL"
        echo "  $EC_CLEANING_AUTH_JSON"
        exit 1
    fi

fi

####################################################

# Cmake configure step
echo "Configuring project in $BUILD_DIR"
cmake -S . -B "$BUILD_DIR"                                         \
    -DFDW_AUTH_SQL="$FDW_AUTH_SQL"                                 \
    -DTOPSIDE_DB_AUTH_SQL="$TOPSIDE_DB_AUTH_SQL"                   \
    -DEC_CLEANING_AUTH_FILENAME="$EC_CLEANING_AUTH_FILENAME"       \
    -DEC_CLEANING_AUTH_SRC_DIR="$SECRET_LOCATION"                  \
    -DEC_CLEANING_AUTH_INSTALL_DIR="$EC_CLEANING_AUTH_INSTALL_DIR" \
    -DCONTAINER_BUILD="$CONTAINER_BUILD"

####################################################

# Build the package
echo "Packaging project into .deb"
cmake --build "$BUILD_DIR" --target package

####################################################
# Cleanup

# Delete temporary keys that were downloaded, but don't do that
# in a docker container since it can cause issues for subsequent builds
# in that container.
# Don't delete the JSON auth file, that's important to retain since
# it's going to be referenced at runtime
if [[ ! "$CONTAINER_BUILD" = "ON" ]]; then
    echo "Deleting local secrets"
    rm -f "$FDW_AUTH_SQL"
    rm -f "$TOPSIDE_DB_AUTH_SQL"
fi

# Move deb back to package root
mv "$BUILD_DIR"/*.deb .
