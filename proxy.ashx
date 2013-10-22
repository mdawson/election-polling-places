<%@ WebHandler Language="C#" Class="proxy" %>
/*
 | Version 10.2
 | Copyright 2013 Esri
 |
 | Licensed under the Apache License, Version 2.0 (the "License");
 | you may not use this file except in compliance with the License.
 | You may obtain a copy of the License at
 |
 |    http://www.apache.org/licenses/LICENSE-2.0
 |
 | Unless required by applicable law or agreed to in writing, software
 | distributed under the License is distributed on an "AS IS" BASIS,
 | WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 | See the License for the specific language governing permissions and
 | limitations under the License.
 */
using System;
using System.IO;
using System.Web;
using System.Collections.Generic;
using System.Text;
using System.Xml.Serialization;
using System.Web.Caching;
using System.Net;                       // for WebRequest & WebResponse
using System.Security.Cryptography;     // for MD5CryptoServiceProvider
//============================================================================================================================//

/// <summary>
/// Handles multiple proxy behaviors:  source-site filtering, ArcGIS Online authentication, app-level Twitter authentication,
/// and cross-domain proxying & filtering with an RSS 2 override.
/// </summary>
public class proxy : IHttpHandler
{
    const bool cShowAuthXHeaders = true;
    const string cConfigFilename = "proxy.config";
    const string cConfigCacheName = "proxy_config";
    const string cCredentialsTagListCacheName = "proxy_credentialTags";
    enum IsAcceptableURL {no, onlyIfRSS, yes};

    public void ProcessRequest(HttpContext context)
    {
        HttpRequest requestFromApp = context.Request;
        HttpResponse responseToApp = context.Response;
        HttpWebRequest requestToThirdPartyServer = null;
        IsAcceptableURL okURL;

        // Read config file
        ProxyConfig config = ProxyConfig.GetCurrentConfig(cConfigFilename, cConfigCacheName);
        if(null == config)
        {
            // Clear the caches for convenience of configurer
            ClearCaches();

            // Report the missing configuration
            responseToApp.StatusCode = 500;
            responseToApp.StatusDescription = "Proxy configuration not available; proxy cache usage cleared";
            responseToApp.End();
            return;
        }

        // Get the URL requested by the client (take the entire querystring at once
        // to handle the case of the URL itself containing querystring parameters);
        // lop off initial question mark of query string
        if (1 >= requestFromApp.Url.Query.Length) {
            // Clear the caches for convenience of configurer
            ClearCaches();

            responseToApp.StatusCode = 200;
            responseToApp.StatusDescription = "Proxy cache usage cleared";
            responseToApp.End();
            return;
        }
        string thirdPartyServerURL = requestFromApp.Url.Query.Substring(1);

        // Check that the third-party URL doesn't contain extra question marks
        int iQ = thirdPartyServerURL.IndexOf("?");
        for (;;)
        {
            if(thirdPartyServerURL.Length <= ++iQ) break;
            iQ = thirdPartyServerURL.IndexOf("?", iQ);
            if(0 > iQ) break;
            thirdPartyServerURL = thirdPartyServerURL.Remove(iQ, 1).Insert(iQ, "&");
        };

        //--------------------------------------------------------------------------------------------------------------------//
        // Are we checking the application's site's URL?
        if (null != config.applicationSiteUrl)
        {
            // Check that the application's server matches the config file
            bool ok = requestFromApp.Url.ToString().ToLower().StartsWith(config.applicationSiteUrl.ToLower());
            if (!ok)
            {
                responseToApp.StatusCode = 500;
                responseToApp.StatusDescription = "Unsupported application URL";
                responseToApp.End();
                return;
            }
        }

        //--------------------------------------------------------------------------------------------------------------------//
        // Are we checking for URL rewriting?
        if (null != config.UrlRewriting)
        {
            foreach (UrlToRewrite rewriteRule in config.UrlRewriting){

                // Is the third-party URL a rewrite candidate?
                if (thirdPartyServerURL.StartsWith(rewriteRule.urlPrefix)) {

                    // Rewrite using AGOL authentication
                    if (null != rewriteRule.agolCredentials) {

                        string cacheTag = MD5.HashString(rewriteRule.urlPrefix);
                        AddToCredentialsTagListCache(cacheTag);
                        if (!PrepareAgolUrl(
                            cacheTag, config.applicationSiteUrl, ref thirdPartyServerURL,
                            rewriteRule.agolCredentials, ref requestToThirdPartyServer, ref responseToApp))
                        {
                            responseToApp.StatusCode = 500;
                            responseToApp.StatusDescription = "ArcGIS.com authentication failed";
                            responseToApp.End();
                            return;
                        }
                        break;
                    }

                    //------------------------------------------------------------------------------------------------------------//

                    // Rewrite using AGOL OAuth2 authentication
                    else if (null != rewriteRule.agolOAuth2Credentials) {

                        string cacheTag = MD5.HashString(rewriteRule.urlPrefix);
                        AddToCredentialsTagListCache(cacheTag);
                        if (!PrepareAgolOAuth2Url(
                            cacheTag, config.applicationSiteUrl, ref thirdPartyServerURL,
                            rewriteRule.agolOAuth2Credentials, ref requestToThirdPartyServer, ref responseToApp))
                        {
                            responseToApp.StatusCode = 500;
                            responseToApp.StatusDescription = "ArcGIS.com authentication failed";
                            responseToApp.End();
                            return;
                        }
                        break;
                    }

                    //------------------------------------------------------------------------------------------------------------//

                    // Rewrite using Twitter authentication
                    else if (null != rewriteRule.twitterCredentials) {

                        string cacheTag = MD5.HashString(rewriteRule.urlPrefix);
                        AddToCredentialsTagListCache(cacheTag);
                        if (!PrepareTwitterUrl(
                            cacheTag, config.applicationSiteUrl, ref thirdPartyServerURL,
                            rewriteRule.twitterCredentials, ref requestToThirdPartyServer, ref responseToApp))
                        {
                            responseToApp.StatusCode = 500;
                            responseToApp.StatusDescription = "Twitter authentication failed";
                            responseToApp.End();
                            return;
                        }
                        break;
                    }
                }
            }
        }

        //--------------------------------------------------------------------------------------------------------------------//
        // Are we filtering server URLs?
        if (null != config.serverUrls)
        {
            okURL = config.serverUrls.exemptRSS2 ? IsAcceptableURL.onlyIfRSS : IsAcceptableURL.no;

            // Find the matching server prefixes in the list of accepted servers.
            // Carry along with the OK any restrictions.
            string lowerThirdPartyServerURL = thirdPartyServerURL.ToLower();
            foreach(serverUrl server in config.serverUrls)
            {
                if (lowerThirdPartyServerURL.StartsWith(server.url.ToLower()))
                {
                    okURL = IsAcceptableURL.yes;
                }
            }

            // Report that the third-party server wasn't in the configured list; we'll defer this if exempting RSS feeds
            if (IsAcceptableURL.no == okURL)
            {
                responseToApp.StatusCode = 500;
                responseToApp.StatusDescription = "Unsupported server URL";
                responseToApp.End();
                return;
            }
        }
        else
        {
            okURL = IsAcceptableURL.yes;
        }

        //--------------------------------------------------------------------------------------------------------------------//
        // At this point, we've done all of the filtering, authenticating, and URL-rewriting that we need to do.
        // Create the web request if a managed URL handler hasn't already done so
        if (null == requestToThirdPartyServer)
        {
            requestToThirdPartyServer = (HttpWebRequest)WebRequest.Create(thirdPartyServerURL);
        }
        requestToThirdPartyServer.Method = context.Request.HttpMethod;
        requestToThirdPartyServer.ServicePoint.Expect100Continue = false;

        // Set body of request for POST requests
        if (context.Request.InputStream.Length > 0)
        {
            byte[] bytes = new byte[context.Request.InputStream.Length];
            context.Request.InputStream.Read(bytes, 0, (int)context.Request.InputStream.Length);
            requestToThirdPartyServer.ContentLength = bytes.Length;

            string ctype = context.Request.ContentType;
            if (String.IsNullOrEmpty(ctype)) {
                requestToThirdPartyServer.ContentType = "application/x-www-form-urlencoded";
            }
            else {
                requestToThirdPartyServer.ContentType = ctype;
            }

            using (Stream outputStream = requestToThirdPartyServer.GetRequestStream())
            {
                outputStream.Write(bytes, 0, bytes.Length);
            }
        }

        // Send the request to the third-party server.
        System.Net.HttpWebResponse responseFromThirdPartyServer = null;
        try
        {
            responseFromThirdPartyServer = (System.Net.HttpWebResponse)requestToThirdPartyServer.GetResponse();
        }
        catch (System.Net.WebException webExc)
        {
            responseToApp.StatusCode = 500;
            responseToApp.StatusDescription = webExc.Status.ToString();
            responseToApp.Write(webExc.Message);
            responseToApp.Write("<br />");
            responseToApp.Write(webExc.Response);
            responseToApp.End();
            return;
        }

        //--------------------------------------------------------------------------------------------------------------------//

        // Set up the response to the client
        if (responseFromThirdPartyServer != null)
        {
            responseToApp.ContentType = responseFromThirdPartyServer.ContentType;
            try
            {
                using (Stream byteStream = responseFromThirdPartyServer.GetResponseStream())
                {
                    if (IsAcceptableURL.onlyIfRSS == okURL)
                    {
                        // Try to parse content as RSS
                        try
                        {
                            string responseString = "";
                            using (MemoryStream ms = new MemoryStream())
                            {
                                // Read the response into local memory
                                using (StreamReader sr = new StreamReader(byteStream))
                                {
                                    responseString = sr.ReadToEnd();
                                    byte[] responseBytes = Encoding.UTF8.GetBytes(responseString);
                                    ms.Write(responseBytes, 0, responseBytes.Length);
                                }

                                // Try to parse it; throws an exception if it fails
                                ms.Seek(0L, SeekOrigin.Begin);
                                rss.ParseFeed(ms);
                            }

                            // Copy the third-party response to the app
                            responseToApp.Write(responseString);
                        }
                        catch (Exception) {
                            responseToApp.StatusCode = 500;
                            responseToApp.StatusDescription = "Unsupported server URL";
                            return;
                        }
                    }
                    else
                    {
                        // Text response
                        if (responseFromThirdPartyServer.ContentType.Contains("text") ||
                            responseFromThirdPartyServer.ContentType.Contains("json"))
                        {
                            using (StreamReader sr = new StreamReader(byteStream))
                            {
                                string responseString = sr.ReadToEnd();
                                responseToApp.Write(responseString);
                            }
                        }
                        else
                        {
                            // Binary response (image, lyr file, other binary file)
                            BinaryReader br = new BinaryReader(byteStream);

                            // If the server provides the Content Length, use it, subject to a maximum
                            // buffer size. But just because the value is zero doesn't mean that the server
                            // didn't send us anything; cf ArcGIS.com & item thumbnails.
                            int numBytes = Math.Min(4096, (int)responseFromThirdPartyServer.ContentLength);
                            if (0 >= numBytes) numBytes = 4096;

                            // Copy to response to app until the response from third party server is empty
                            int bytesRead = 0;
                            do
                            {
                                byte[] outb = br.ReadBytes(numBytes);
                                bytesRead = outb.Length;
                                if (0 < bytesRead) responseToApp.OutputStream.Write(outb, 0, bytesRead);
                            } while (0 < bytesRead);

                            br.Close();
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                responseToApp.StatusCode = 500;
                responseToApp.StatusDescription = ex.Message.ToString();
                responseToApp.Write(ex.Message);
            }
            responseFromThirdPartyServer.Close();
        }
        // Report that the third-party server wasn't in the configured list
        else if (IsAcceptableURL.onlyIfRSS == okURL)
        {
            responseToApp.StatusCode = 500;
            responseToApp.StatusDescription = "Unsupported server URL";
        }

        responseToApp.End();
    }

    //------------------------------------------------------------------------------------------------------------------------//

    public bool IsReusable
    {
        get {
            return true;
        }
    }

    /// <summary>
    /// Adapts the called URL for use with AGOL.
    /// </summary>
    /// <param name="cacheTag">Tag for token cache</param>
    /// <param name="referer">URL of calling application's site</param>
    /// <param name="thirdPartyServerURL">Called URL</param>
    /// <param name="agolCredentials">AGOL username/password authentication credentials</param>
    /// <param name="requestToThirdPartyServer">Overwritten by proxy request to third-party server
    /// created by this routine</param>
    /// <param name="responseToApp">Response to calling application; provided so that diagnostic
    /// information may be inserted into the response's headers</param>
    /// <returns>True if called URL successfully adapted for calling AGOL</returns>
    protected bool PrepareAgolUrl(string cacheTag,
        string referer, ref string thirdPartyServerURL, agolCredentials agolCredentials,
        ref HttpWebRequest requestToThirdPartyServer, ref HttpResponse responseToApp)
    {
        // Try to get the authentication spec from the cache
        bool usedCache = true;
        string authExpiration = "";
        AGOLAuthenticationSpec authSpec = HttpRuntime.Cache[cacheTag] as AGOLAuthenticationSpec;
        if (authSpec == null)
        {
            usedCache = false;
            // No spec available--we'll have to generate one

            // Pick a username; we can have multiple to spread out the load
            int iUser = 0;
            string[] usernames = agolCredentials.usernames.Split(new Char[] {','});
            if(1 < usernames.Length)
            {
                iUser = (new Random()).Next(usernames.Length);
            }

            string[] passwords = agolCredentials.passwords.Split(new Char[] {','});
            iUser = Math.Min(iUser, passwords.Length - 1);

            string username = usernames[iUser];
            string password = passwords[iUser];
            responseToApp.Headers["X-UserNum"] = (++iUser).ToString();

            // Post the authentication request
            System.Net.HttpWebRequest authenticationReq =
                (System.Net.HttpWebRequest)System.Net.HttpWebRequest.Create(
                agolCredentials.authenticationUrl);
            authenticationReq.Method = "POST";
            authenticationReq.ContentType = "application/x-www-form-urlencoded; charset=UTF-8";
            authenticationReq.ServicePoint.Expect100Continue = false;

            string postData =
                "referer=" + (null != referer ? referer : "") +
                "&username=" + username +
                "&password=" + password +
                "&expiration=" + agolCredentials.tokenCacheDurationMinutes.ToString() +
                "&f=pjson";
            byte[] postBytes = UTF8Encoding.UTF8.GetBytes(postData);
            authenticationReq.ContentLength = postBytes.Length;
            using (Stream outputStream = authenticationReq.GetRequestStream())
            {
                outputStream.Write(postBytes, 0, postBytes.Length);
            }

            // Read the authentication response
            System.Net.HttpWebResponse authenticationResponse = null;
            try
            {
                authenticationResponse = (System.Net.HttpWebResponse)authenticationReq.GetResponse();
            }
            catch (System.Net.WebException)
            {
                authenticationResponse = null;
            }

            if (authenticationResponse != null)
            {
                try
                {
                    using (Stream byteStream = authenticationResponse.GetResponseStream())
                    {
                        System.Runtime.Serialization.Json.DataContractJsonSerializer jsonSer =
                            new System.Runtime.Serialization.Json.DataContractJsonSerializer(
                            typeof(AGOLAuthenticationSpec));
                        authSpec = (AGOLAuthenticationSpec)jsonSer.ReadObject(byteStream);
                    }
                    if (null != authSpec.error)
                    {
                        authSpec = null;
                    }
                }
                catch(Exception ex)
                {
                    authSpec = null;
                }
                authenticationResponse.Close();
            }

            // Cache the authentication
            if (null != authSpec)
            {
                DateTime expiresDate =
                    new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)
                    .AddMilliseconds(authSpec.expires);
                HttpRuntime.Cache.Insert(
                    cacheTag, authSpec, null, expiresDate, Cache.NoSlidingExpiration);

                authExpiration = expiresDate.ToShortDateString() + " " + expiresDate.ToShortTimeString() + " UTC";
                responseToApp.Headers["X-AuthExpiration"] = authExpiration;
            }
            else
            {
                return false;
            }
        }
        else
        {
            DateTime expiresDate =
                new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)
                .AddMilliseconds(authSpec.expires);
            authExpiration = expiresDate.ToShortDateString() + " " + expiresDate.ToShortTimeString() + " UTC";
        }

        responseToApp.Headers["X-FromCache"] = usedCache.ToString();
        responseToApp.Headers["X-AuthExpiration"] = authExpiration;

        // Switch to SSL if desired by authentication response
        if (authSpec.ssl && 5 < thirdPartyServerURL.Length)
        {
            string protocol = thirdPartyServerURL.Substring(0, 5).ToLower();
            if ("http:" == protocol)
            {
                thirdPartyServerURL = "https:" + thirdPartyServerURL.Substring(5);
            }
        }

        // Create the proxied URL
        thirdPartyServerURL += (thirdPartyServerURL.Contains("?") ? "&token=": "?token=") + authSpec.token;

        // Create the request because we need to include the referer in the headers
        requestToThirdPartyServer = (HttpWebRequest)WebRequest.Create(thirdPartyServerURL);
        requestToThirdPartyServer.Referer = referer;

        return true;
    }

    /// <summary>
    /// Adapts the called URL for use with AGOL.
    /// </summary>
    /// <param name="cacheTag">Tag for token cache</param>
    /// <param name="referer">URL of calling application's site</param>
    /// <param name="thirdPartyServerURL">Called URL</param>
    /// <param name="agolOAuth2Credentials">AGOL OAuth2 authentication credentials</param>
    /// <param name="requestToThirdPartyServer">Overwritten by proxy request to third-party server
    /// created by this routine</param>
    /// <param name="responseToApp">Response to calling application; provided so that diagnostic
    /// information may be inserted into the response's headers</param>
    /// <returns>True if called URL successfully adapted for calling AGOL</returns>
    protected bool PrepareAgolOAuth2Url(string cacheTag,
        string referer, ref string thirdPartyServerURL, agolOAuth2Credentials agolOAuth2Credentials,
        ref HttpWebRequest requestToThirdPartyServer, ref HttpResponse responseToApp)
    {
        // Try to get the authentication spec from the cache
        bool usedCache = true;
        string authExpiration = "";
        AGOLOAuth2AuthenticationSpec authSpec =
            HttpRuntime.Cache[cacheTag] as AGOLOAuth2AuthenticationSpec;
        if (authSpec == null)
        {
            usedCache = false;
            // No spec available--we'll have to generate one
            // https://developers.arcgis.com/en/authentication/app-logins.html

            // Obtain a token
            System.Net.HttpWebRequest authenticationReq =
                (System.Net.HttpWebRequest)System.Net.HttpWebRequest.Create(
                agolOAuth2Credentials.authenticationUrl);
            authenticationReq.Method = "POST";
            authenticationReq.ContentType = "application/x-www-form-urlencoded;charset=UTF-8";
            string postData = "client_id=" + agolOAuth2Credentials.appId + "&client_secret="
                + agolOAuth2Credentials.appSecret + "&grant_type=client_credentials";
            byte[] postBytes = UTF8Encoding.UTF8.GetBytes(postData);
            authenticationReq.ContentLength = postBytes.Length;
            using (Stream outputStream = authenticationReq.GetRequestStream())
            {
                outputStream.Write(postBytes, 0, postBytes.Length);
            }
            authenticationReq.ServicePoint.Expect100Continue = false;

            // Read the authentication response
            System.Net.HttpWebResponse authenticationResponse = null;
            try
            {
                authenticationResponse = (System.Net.HttpWebResponse)authenticationReq.GetResponse();
            }
            catch (System.Net.WebException)
            {
                authenticationResponse = null;
            }

            if (authenticationResponse != null)
            {
                try
                {
                    using (Stream byteStream = authenticationResponse.GetResponseStream())
                    {
                        System.Runtime.Serialization.Json.DataContractJsonSerializer jsonSer =
                            new System.Runtime.Serialization.Json.DataContractJsonSerializer(
                            typeof(AGOLOAuth2AuthenticationSpec));
                        authSpec = (AGOLOAuth2AuthenticationSpec)jsonSer.ReadObject(byteStream);
                    }
                }
                catch(Exception ex)
                {
                    authSpec = null;
                }
                authenticationResponse.Close();
            }

            // Cache the authentication
            if (null != authSpec)
            {
                DateTime expiresDate = DateTime.UtcNow
                    .AddMinutes(authSpec.expires_in);
                HttpRuntime.Cache.Insert(
                    cacheTag, authSpec, null, expiresDate, Cache.NoSlidingExpiration);

                authExpiration = expiresDate.ToShortDateString() + " " + expiresDate.ToShortTimeString() + " UTC";
                responseToApp.Headers["X-AuthExpiration"] = authExpiration;
            }
            else
            {
                return false;
            }
        }

        responseToApp.Headers["X-FromCache"] = usedCache.ToString();

        // Create the proxied URL
        thirdPartyServerURL += (thirdPartyServerURL.Contains("?") ? "&token=": "?token=") + authSpec.access_token;

        // Create the request because we need to include the referer in the headers
        requestToThirdPartyServer = (HttpWebRequest)WebRequest.Create(thirdPartyServerURL);
        requestToThirdPartyServer.Referer = referer;

        return true;
    }

    /// <summary>
    /// Adapts the called URL for use with Twitter.
    /// </summary>
    /// <param name="cacheTag">Tag for token cache</param>
    /// <param name="referer">URL of calling application's site</param>
    /// <param name="thirdPartyServerURL">Called URL</param>
    /// <param name="twitterCredentials">Twitter authentication credentials</param>
    /// <param name="requestToThirdPartyServer">Overwritten by proxy request to third-party server
    /// created by this routine</param>
    /// <param name="responseToApp">Response to calling application; provided so that diagnostic
    /// information may be inserted into the response's headers</param>
    /// <returns>True if called URL successfully adapted for calling Twitter</returns>
    protected bool PrepareTwitterUrl(string cacheTag,
        string referer, ref string thirdPartyServerURL, twitterCredentials twitterCredentials,
        ref HttpWebRequest requestToThirdPartyServer, ref HttpResponse responseToApp)
    {
        // Try to get the authentication spec from the cache
        bool usedCache = true;
        string authExpiration = "";
        TwitterAuthenticationSpec authSpec =
            HttpRuntime.Cache[cacheTag] as TwitterAuthenticationSpec;
        if (authSpec == null)
        {
            usedCache = false;
            // No spec available--we'll have to generate one
            // https://dev.twitter.com/docs/auth/application-only-auth

            // "Step 1: Encode consumer key and secret"
            string authHeader = Encode_Base64(
                Encode_RFC1738(twitterCredentials.consumerKey)
                + ":" + Encode_RFC1738(twitterCredentials.consumerSecret));

            // "Step 2: Obtain a bearer token"
            System.Net.HttpWebRequest authenticationReq =
                (System.Net.HttpWebRequest)System.Net.HttpWebRequest.Create(
                twitterCredentials.authenticationUrl);
            authenticationReq.Method = "POST";
            authenticationReq.Headers.Add("Authorization", "Basic " + authHeader);
            authenticationReq.ContentType = "application/x-www-form-urlencoded;charset=UTF-8";
            string postData = "grant_type=client_credentials";
            byte[] postBytes = UTF8Encoding.UTF8.GetBytes(postData);
            authenticationReq.ContentLength = postBytes.Length;
            using (Stream outputStream = authenticationReq.GetRequestStream())
            {
                outputStream.Write(postBytes, 0, postBytes.Length);
            }
            authenticationReq.ServicePoint.Expect100Continue = false;

            // Read the authentication response
            System.Net.HttpWebResponse authenticationResponse = null;
            try
            {
                authenticationResponse = (System.Net.HttpWebResponse)authenticationReq.GetResponse();
            }
            catch (System.Net.WebException)
            {
                authenticationResponse = null;
            }

            if (authenticationResponse != null)
            {
                try
                {
                    using (Stream byteStream = authenticationResponse.GetResponseStream())
                    {
                        System.Runtime.Serialization.Json.DataContractJsonSerializer jsonSer =
                            new System.Runtime.Serialization.Json.DataContractJsonSerializer(
                            typeof(TwitterAuthenticationSpec));
                        authSpec = (TwitterAuthenticationSpec)jsonSer.ReadObject(byteStream);
                    }
                }
                catch(Exception ex)
                {
                    authSpec = null;
                }
                authenticationResponse.Close();
            }

            // Cache the authentication
            if (null != authSpec)
            {
                DateTime expiresDate = DateTime.UtcNow
                    .AddMinutes(twitterCredentials.tokenCacheDurationMinutes);
                HttpRuntime.Cache.Insert(
                    cacheTag, authSpec, null, expiresDate, Cache.NoSlidingExpiration);

                authExpiration = expiresDate.ToShortDateString() + " " + expiresDate.ToShortTimeString() + " UTC";
                responseToApp.Headers["X-AuthExpiration"] = authExpiration;
            }
            else
            {
                return false;
            }
        }

        responseToApp.Headers["X-FromCache"] = usedCache.ToString();

        // "Step 3: Authenticate API requests with the bearer token"
        requestToThirdPartyServer = (HttpWebRequest)WebRequest.Create(thirdPartyServerURL);
        requestToThirdPartyServer.Headers.Add("Authorization", "Bearer " + authSpec.access_token);

        return true;
    }

    /// <summary>
    /// Cache a credential used by this proxy.
    /// </summary>
    protected void AddToCredentialsTagListCache(string cacheTag)
    {
        string tags = HttpRuntime.Cache[cCredentialsTagListCacheName] as string;

        // No cache tag names stored yet
        if (null == tags)
        {
            HttpRuntime.Cache[cCredentialsTagListCacheName] = cacheTag;
        }

        // Add cache tag name if it isn't there already
        else if (!tags.Contains(cacheTag))
        {
            tags += "|" + cacheTag;
            HttpRuntime.Cache[cCredentialsTagListCacheName] = tags;
        }
    }

    /// <summary>
    /// Clears the runtime caches used by this proxy.
    /// </summary>
    protected void ClearCaches()
    {
        string tags = HttpRuntime.Cache[cCredentialsTagListCacheName] as string;
        if (null == tags)
        {
            return;
        }

        // Run thru the list of cache tag names clearing each one
        string[] tagList = tags.Split(new char[]{'|'});
        foreach (string tag in tagList)
        {
            HttpRuntime.Cache.Remove(tag);
        }

        // Then clear list of tag names
        HttpRuntime.Cache.Remove(cCredentialsTagListCacheName);
    }

    /// <summary>
    /// Escapes a string using OAuth rules.
    /// </summary>
    /// <param name="rawString">Original string</param>
    /// <returns>Escaped string</returns>
    protected string OAuthEscape(string rawString)
    {
        StringBuilder escapedString = new StringBuilder();
        for (int i = 0; i < rawString.Length; ++i)
        {
            char rawChar = rawString[i];

            // http://tools.ietf.org/html/rfc5849#section-3.6
            // Characters in the unreserved character set as defined by [RFC3986], Section 2.3
            // (ALPHA, DIGIT, "-", ".", "_", "~") MUST NOT be encoded.
            if (Char.IsLetterOrDigit(rawChar) || '-' == rawChar || '.' == rawChar || '_' == rawChar || '~' == rawChar)
            {
                escapedString.Append(rawChar);
            }
            else
            {
                escapedString.Append("%");
                escapedString.Append(((int)rawChar).ToString("X2"));
            }
        }
        return escapedString.ToString();
    }

    /// <summary>
    /// Returns the current date and time in Unix format.
    /// </summary>
    /// <returns>Date and time string</returns>
    protected long UnixDate()
    {
        DateTime cUnixStartInWindows = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        TimeSpan unixOffset = DateTimeOffset.Now - cUnixStartInWindows;
        return Convert.ToInt64(Math.Round(unixOffset.TotalMilliseconds));
    }

    /// <summary>
    /// Encodes a string according to the rules of RFC 2396, which supplanted RFC 1738.
    /// </summary>
    /// <param name="original">String to encode</param>
    /// <returns>Encoded string</returns>
    protected string Encode_RFC1738(string original)
    {
        // RFC 2396 "revises and replaces the generic definitions in RFC 1738..."
        // http://www.ietf.org/rfc/rfc2396.txt, http://www.ietf.org/rfc/rfc1738.txt
        // http://msdn.microsoft.com/en-us/library/system.uri.escapedatastring.aspx
        return Uri.EscapeDataString(original);
    }

    /// <summary>
    /// Encodes a string according to the rules of Base 64.
    /// </summary>
    /// <param name="original">String to encode</param>
    /// <returns>Encoded string</returns>
    protected string Encode_Base64(string original)
    {
        return Convert.ToBase64String(
            (new ASCIIEncoding()).GetBytes(original));
    }

}

//============================================================================================================================//

public class MD5
{
    // How to compute and compare hash values by using Visual C#
    // http://support.microsoft.com/kb/307020
    // We don't cache the created provider because the site above says
    // "Note that to compute another hash value, you will need to create
    // another instance of the class."

    public static string HashString(string sourceString)
    {
        return MD5.ByteArrayToString(new MD5CryptoServiceProvider()
            .ComputeHash(ASCIIEncoding.ASCII.GetBytes(sourceString)));
    }

    public static string ByteArrayToString(byte[] arrInput)
    {
        int i;
        StringBuilder sOutput = new StringBuilder(arrInput.Length);
        for (i = 0; i < arrInput.Length; i++)
        {
            sOutput.Append(arrInput[i].ToString("x2"));
        }
        return sOutput.ToString();
    }
}

//============================================================================================================================//

/// <summary>
/// Represents the contents of the config file and provides routines for accessing those contents.
/// </summary>
[XmlRoot("ProxyConfig")]
public class ProxyConfig
{
    #region Static Members

    /// <summary>
    /// Gets the current configuration from the cache if possible and falling back to a file.
    /// </summary>
    /// <param name="configFilename">Name of configuration file</param>
    /// <param name="configCacheName">Name under which to cache configuration</param>
    /// <returns>ProxyConfig object</returns>
    public static ProxyConfig GetCurrentConfig(string configFilename, string configCacheName)
    {
        ProxyConfig config = HttpRuntime.Cache[configCacheName] as ProxyConfig;

        if (config == null)
        {
            string contextualizedFilename = ContextualizeFilename(configFilename, HttpContext.Current);
            config = LoadProxyConfig(contextualizedFilename);

            if (config != null)
            {
                CacheDependency dep = new CacheDependency(contextualizedFilename);
                HttpRuntime.Cache.Insert(configCacheName, config, dep);
            }
        }

        return config;
    }

    /// <summary>
    /// Maps the name of the configuration file to the current context.
    /// </summary>
    /// <param name="configFilename">Name of configuration file</param>
    /// <param name="context">HttpContext of request</param>
    /// <returns>Path to and name of file</returns>
    private static string ContextualizeFilename(string configFilename, HttpContext context)
    {
        return context.Server.MapPath("~/" + configFilename);
    }

    private static object _lockobject = new object();

    /// <summary>
    /// Loads the specified configuration file and deserializes it from XML.
    /// </summary>
    /// <param name="filename">Path to and name of file</param>
    /// <returns>ProxyConfig object</returns>
    private static ProxyConfig LoadProxyConfig(string filename)
    {
        ProxyConfig config = null;

        lock (_lockobject)
        {
            if (System.IO.File.Exists(filename))
            {
                XmlSerializer reader = new XmlSerializer(typeof(ProxyConfig));
                using (StreamReader file = new StreamReader(filename))
                {
                    config = (ProxyConfig)reader.Deserialize(file);
                }
            }
        }

        return config;
    }

    #endregion

    // URL of calling program
    [XmlElement("applicationSiteUrl")]
    public string applicationSiteUrl;

    // URLs managed by proxy
    [XmlArray("UrlRewriting")]
    [XmlArrayItem("UrlToRewrite")]
    public UrlToRewrite[] UrlRewriting;

    // URLs that proxy may call on behalf of calling program
    [XmlElement("serverUrls")]
    public serverUrls serverUrls;
}

//============================================================================================================================//

/// <summary>
/// Represents a URL managed by the proxy, perhaps including adding authentication.
/// </summary>
[XmlRoot("UrlToRewrite")]
public class UrlToRewrite
{
    // Prefix of the URL for matching
    [XmlAttribute("urlPrefix")]
    public string urlPrefix;

    [XmlElement("agolCredentials")]
    public agolCredentials agolCredentials;

    [XmlElement("agolOAuth2Credentials")]
    public agolOAuth2Credentials agolOAuth2Credentials;

    [XmlElement("twitterCredentials")]
    public twitterCredentials twitterCredentials;

    public bool ShouldSerializeagolCredentials()
    {
        return null != agolCredentials;
    }

    public bool ShouldSerializetwitterCredentials()
    {
        return null != twitterCredentials;
    }
}

//============================================================================================================================//

/// <summary>
/// Represents information needed to log into AGOL using username/password.
/// </summary>
[XmlRoot("agolCredentials")]
public class agolCredentials
{
    // URL of AGOL username/password authentication server
    [XmlElement("authenticationUrl")]
    public string authenticationUrl;

    [XmlElement("usernames")]
    public string usernames;

    [XmlElement("passwords")]
    public string passwords;

    [XmlElement("tokenCacheDurationMinutes")]
    public int tokenCacheDurationMinutes;
}

//============================================================================================================================//

/// <summary>
/// Represents information needed to log into AGOL using OAuth2.
/// </summary>
[XmlRoot("agolOAuth2Credentials")]
public class agolOAuth2Credentials
{
    // URL of AGOL OAuth2 authentication server
    [XmlElement("authenticationUrl")]
    public string authenticationUrl;

    [XmlElement("appId")]
    public string appId;

    [XmlElement("appSecret")]
    public string appSecret;

    [XmlElement("tokenCacheDurationMinutes")]
    public int tokenCacheDurationMinutes;
}

//============================================================================================================================//

/// <summary>
/// Represents information needed to log into Twitter using OAuth2.
/// </summary>
[XmlRoot("twitterCredentials")]
public class twitterCredentials
{
    // URL of Twitter authentication server
    [XmlElement("authenticationUrl")]
    public string authenticationUrl;

    [XmlElement("consumerKey")]
    public string consumerKey;

    [XmlElement("consumerSecret")]
    public string consumerSecret;

    [XmlElement("tokenCacheDurationMinutes")]
    public int tokenCacheDurationMinutes;
}

//============================================================================================================================//

/// <summary>
/// Represents a list of servers that the proxy may contact.
/// </summary>
[XmlRoot("serverUrls")]
public class serverUrls
{
    // Switch indicating if RSS feeds are exempt from restriction; defaults to "false"
    [XmlAttribute("exemptRSS2")]
    public bool exemptRSS2;

    // List of servers
    private readonly List<serverUrl> items = new List<serverUrl>();
    [XmlElement("serverUrl", typeof(serverUrl))]
    public List<serverUrl> Items { get { return items; } }
    public int Count { get { return items.Count; } }
    public List<serverUrl>.Enumerator GetEnumerator() { return items.GetEnumerator(); }
}

//============================================================================================================================//

/// <summary>
/// Represents a server that the proxy may contact.
/// </summary>
[XmlRoot("serverUrl")]
public class serverUrl
{
    // Prefix of the URL for matching
    [XmlAttribute("url")]
    public string url;
}

//============================================================================================================================//

/// <summary>
/// Represents the contents of the authentication specification returned from arcgis.com after a username/password authentication.
/// </summary>
[System.Runtime.Serialization.DataContract]
public class AGOLAuthenticationSpec
{
    [System.Runtime.Serialization.DataMember]
    public string token;

    [System.Runtime.Serialization.DataMember]
    public long expires;

    [System.Runtime.Serialization.DataMember]
    public bool ssl;

    [System.Runtime.Serialization.DataMember]
    public object error;
}

//============================================================================================================================//

/// <summary>
/// Represents the contents of the authentication specification returned from arcgis.com after an OAuth2 authentication.
/// </summary>
[System.Runtime.Serialization.DataContract]
public class AGOLOAuth2AuthenticationSpec
{
    [System.Runtime.Serialization.DataMember]
    public string access_token;

    [System.Runtime.Serialization.DataMember]
    public long expires_in;

    [System.Runtime.Serialization.DataMember]
    public object error;
}

//============================================================================================================================//

/// <summary>
/// Represents the contents of the authentication specification returned from twitter.com.
/// </summary>
[System.Runtime.Serialization.DataContract]
public class TwitterAuthenticationSpec
{
    [System.Runtime.Serialization.DataMember]
    public string token_type;

    [System.Runtime.Serialization.DataMember]
    public string access_token;
}

//============================================================================================================================//

/// <summary>
/// Represents a simple RSS 2 XML content.
/// </summary>
[XmlRoot]
public class rss
{
    [XmlAttribute]
    public string version;

    [XmlElement]
    public channel channel;

    public static rss ParseFeed(Stream source)
    {
        rss feed = null;

        XmlSerializer reader = new XmlSerializer(typeof(rss));
        using (StreamReader src = new StreamReader(source))
        {
            feed = (rss)reader.Deserialize(src);
        }

        return feed;
    }
}

[XmlRoot]
public class channel
{
    [XmlElement]
    public string title;

    [XmlElement]
    public string description;

    [XmlElement]
    public string link;

    [XmlElement("item")]
    public item[] items;
}

[XmlRoot]
public class item
{
    [XmlElement]
    public string category;

    [XmlElement]
    public string title;

    [XmlElement]
    public string description;

    [XmlElement]
    public string link;

    [XmlElement]
    public guidItem guid;

    [XmlElement]
    public string pubDate;
}

[XmlRoot]
public class guidItem
{
    [XmlAttribute]
    public string isPermaLink;

    [XmlText]
    public string guid;
}