#!/bin/bash -e
# Copyright 2023 WSO2, LLC. http://www.wso2.org
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ----------------------------------------------------------------------------
# USAGE METERING TEST SCENARIOS
# ----------------------------------------------------------------------------
# Only the two metering-relevant scenarios are active:
#   00 - client_credentials grant  -> M2M_TOKEN metering
#   09 - password grant            -> MAU (AUTHENTICATION_SUCCESS) metering
# Both run in tenant mode (100 tenants x 1000 users) so MAU is exercised
# per-tenant. All other stock scenarios are disabled (see the block at the
# bottom of this file). To restore the full suite, move them back out.
# ----------------------------------------------------------------------------

# M2M token metering (client credentials). tenantMode=true -> per-tenant clients.
declare -A test_scenario0=(
    [name]="00-oauth_client_credential_grant"
    [display_name]="Client Credentials Grant Type (M2M metering)"
    [description]="Obtain an access token using the OAuth 2.0 client credential grant type; drives M2M_TOKEN metering."
    [jmx]="oauth/OAuth_Client_Credentials_Grant.jmx"
    [tenantMode]=true
    [skip]=false
    [modes]="FULL PUBLISH"
)

# MAU metering (password grant). Every request fires AUTHENTICATION_SUCCESS.
declare -A test_scenario9=(
    [name]="09-oidc_password_grant"
    [display_name]="OIDC Password Grant Type (MAU metering)"
    [description]="Obtain an access token using the OAuth 2.0 password grant type; drives MAU metering."
    [jmx]="oidc/OIDC_Password_Grant.jmx"
    [tenantMode]=true
    [skip]=false
    [modes]="FULL QUICK PUBLISH"
)

# ============================================================================
# DISABLED stock scenarios (kept for reference; not registered because they are
# inside this heredoc). Move any block above this line to re-enable it.
# ============================================================================
: <<'DISABLED_SCENARIOS'
declare -A test_scenario1=(
    [name]="01-oidc_auth_code_redirect_with_consent"
    [jmx]="oidc/OIDC_AuthCode_Redirect_WithConsent.jmx"
)
declare -A test_scenario2=(
    [name]="02-oidc_auth_code_redirect_with_consent_retrieve_user_attributes"
    [jmx]="oidc/OIDC_AuthCode_Redirect_WithConsent_Retrieve_User_Attributes.jmx"
)
declare -A test_scenario03=(
    [name]="03-oidc_auth_code_redirect_with_consent_retrieve_user_attributes_and_groups"
    [jmx]="oidc/OIDC_AuthCode_Redirect_WithConsent_Retrieve_User_Attributes_And_Groups.jmx"
)
declare -A test_scenario04=(
    [name]="04-oidc_auth_code_redirect_with_consent_retrieve_user_attributes_groups_and_roles"
    [jmx]="oidc/OIDC_AuthCode_Redirect_WithConsent_Retrieve_User_Attributes_Groups_And_Roles.jmx"
)
declare -A test_scenario05=(
    [name]="05-oidc_auth_code_redirect_without_consent"
    [jmx]="oidc/OIDC_AuthCode_Redirect_WithoutConsent.jmx"
)
declare -A test_scenario06=(
    [name]="06-oidc_auth_code_redirect_without_consent_retrieve_user_attributes"
    [jmx]="oidc/OIDC_AuthCode_Redirect_WithoutConsent_Retrieve_User_Attributes.jmx"
)
declare -A test_scenario07=(
    [name]="07-oidc_auth_code_redirect_without_consent_retrieve_user_attributes_and_groups"
    [jmx]="oidc/OIDC_AuthCode_Redirect_WithoutConsent_Retrieve_User_Attributes_And_Groups.jmx"
)
declare -A test_scenario08=(
    [name]="08-oidc_auth_code_redirect_without_consent_retrieve_user_attributes_groups_and_roles"
    [jmx]="oidc/OIDC_AuthCode_Redirect_WithoutConsent_Retrieve_User_Attributes_Groups_And_Roles.jmx"
)
declare -A test_scenario10=(
    [name]="10-oidc_password_grant_retrieve_user_attributes"
    [jmx]="oidc/OIDC_Password_Grant_Retrieve_User_Attributes.jmx"
)
declare -A test_scenario11=(
    [name]="11-oidc_password_grant_retrieve_user_attributes_and_groups"
    [jmx]="oidc/OIDC_Password_Grant_Retrieve_User_Attributes_And_Groups.jmx"
)
declare -A test_scenario12=(
    [name]="12-oidc_password_grant_retrieve_user_attributes_groups_and_roles"
    [jmx]="oidc/OIDC_Password_Grant_Retrieve_User_Attributes_Groups_And_Roles.jmx"
)
declare -A test_scenario13=(
    [name]="13-saml2_sso_redirect_binding"
    [jmx]="saml/SAML2_SSO_Redirect_Binding.jmx"
)
declare -A test_scenario14=(
    [name]="14-Token_Exchange_Grant"
    [jmx]="oauth/Token_Exchange_Grant.jmx"
)
declare -A test_scenario15=(
    [name]="15-B2B_oidc_auth_code_redirect_with_consent"
    [jmx]="oidc/B2B_OIDC_AuthCode_Redirect_WithConsent.jmx"
)
declare -A test_scenario16=(
    [name]="16-App_Native_Auth"
    [jmx]="app-native-auth/App_Native_Auth.jmx"
)
DISABLED_SCENARIOS
