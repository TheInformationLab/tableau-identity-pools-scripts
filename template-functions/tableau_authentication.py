"""This module handles manual sign in tasks for accessing the Tableau Server REST API"""

import json
import logging
import requests

logger = logging.getLogger(__name__)

def get_api_version(server_url:str):
    """Function to get latest API version in use on the provided server"""
    header = {
        "accept":"application/json"
        }
    server_info = json.loads(
        requests.get(
            server_url+"api/2.4/serverinfo",
            headers=header,
            timeout=5)
        .text
        )
    api_version = server_info["serverInfo"]["restApiVersion"]
    return api_version

def get_auth_response(
    token_name,
    token_secret,
    server_url,
    site_uri,
    api_version
    ):
    """Function to get authentication token for subsequent API calls"""
    # set data types for request bodies
    header = {
        "Content-Type": "application/xml",
        "Accept":"application/json"
        }
    # get sign in details
    # sign in url
    signin_endpoint = f"{server_url}api/{api_version}/auth/signin"
    # body including credentials
    # this is xml as only xml example is provided in the Tableau docs
    signin_body = (
        f'<tsRequest><credentials personalAccessTokenName="{token_name}" '
        f'personalAccessTokenSecret="{token_secret}">'
        f'<site contentUrl="{site_uri}" /></credentials></tsRequest>'
    )
    # send signin request
    auth_resp = requests.post(
        signin_endpoint,
        headers=header,
        data=signin_body,
        timeout=5
        )
    logger.info("Sign in response code: %d", auth_resp.status_code)
    # test authentication response
    if auth_resp.status_code == 200:
        # parse response for site id and X-Tableau-Auth token
        r = json.loads(auth_resp.text)
        site_id = parse_site_id(r)
        tab_auth = parse_x_tableau_auth(r)
        return site_id, tab_auth
    raise requests.HTTPError(f"Sign in failed: {auth_resp.status_code} - {auth_resp.text}")

def parse_site_id(auth_response):
    """Function to parse site ID from authentication response."""
    # parse signin response
    try:
        site_id = auth_response['credentials']['site']['id']
    except KeyError as exc:
        raise KeyError("Site ID not found") from exc
    return site_id

def parse_x_tableau_auth(auth_response):
    """Function to parse authentication token from authentication response."""
    # parse signin response
    try:
        token = auth_response['credentials']['token']
    except KeyError as exc:
        raise KeyError("REST API authentication token not found") from exc
    return token

def sign_out(
    server_url,
    api_version,
    auth_token
    ):
    """Function to sign out from server"""
    sign_out_endpoint = f"{server_url}api/{api_version}/auth/signout"
    auth_header = {"X-Tableau-Auth":auth_token}
    resp = requests.post(sign_out_endpoint,headers=auth_header,timeout=10)
    if resp.status_code == 204:
        logger.info("Successfully signed out")
    else:
        raise requests.HTTPError(f"Sign out failed: {resp.status_code} - {resp.text}")
