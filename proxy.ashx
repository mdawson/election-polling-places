<%@ WebHandler Language="C#" Class="proxy" %>

/* Version 2.0
 *
 * What's new:
 * - supports OAuth2 AppLogin-based authentication
 * - rate limiting (resource + referrer based)
 * - optional logging
 * - .NET 4.0 or higher
*/

using System;
using System.IO;
using System.Web;
using System.Xml.Serialization;
using System.Web.Caching;
using System.Collections.Concurrent;

public class proxy : IHttpHandler {

    class RateMeter {
        double _rate; //internal rate is stored in requests per second
        int _countCap;
        double _count = 0;
        DateTime _lastUpdate = DateTime.Now;

        public RateMeter(int rate_limit, int rate_limit_period) {
            _rate = (double) rate_limit / rate_limit_period / 60;
            _countCap = rate_limit;
        }

        //called when rate-limited endpoint is invoked
        public bool click() {
            TimeSpan ts = DateTime.Now - _lastUpdate;
            _lastUpdate = DateTime.Now;
            //assuming uniform distribution of requests over time,
            //reducing the counter according to # of seconds passed
            //since last invocation
            _count = Math.Max(0, _count - ts.TotalSeconds * _rate);
            if (_count <= _countCap) {
                //good to proceed
                _count++;
                return true;
            }
            return false;
        }

        public bool canBeCleaned() {
            TimeSpan ts = DateTime.Now - _lastUpdate;
            return _count - ts.TotalSeconds * _rate <= 0;
        }
    }

    private static string PROXY_REFERER = "http://localhost/auth_proxy.ashx";
    private static string DEFAULT_OAUTH = "https://www.arcgis.com/sharing/oauth2/";
    private static int CLEAN_RATEMAP_AFTER = 10000; //clean the rateMap every xxxx requests

    private static Object _rateMapLock = new Object();

    public void ProcessRequest(HttpContext context) {
        HttpResponse response = context.Response;

        string uri = context.Request.Url.Query.Substring(1);
        log(uri);
        ServerUrl serverUrl;
        bool passThrough = false;
        try {
            serverUrl = getConfig().GetConfigServerUrl(uri);
            passThrough = serverUrl == null;
        } catch (InvalidOperationException) {
            log("[Error]: Proxy is being used for an unsupported service (proxy.config has mustMatch=\"true\"): " + uri);
            response = HttpContext.Current.Response;
            response.StatusCode = (int)System.Net.HttpStatusCode.Forbidden;
            response.End();
            return;
        }

        //Throttling: checking the rate limit coming from particular client IP
        if (!passThrough && serverUrl.RateLimit > -1) {
            lock (_rateMapLock)
            {
                ConcurrentDictionary<string, RateMeter> ratemap = (ConcurrentDictionary<string, RateMeter>)context.Application["rateMap"];
                if (ratemap == null)
                {
                    ratemap = new ConcurrentDictionary<string, RateMeter>();
                    context.Application["rateMap"] = ratemap;
                    context.Application["rateMap_cleanup_counter"] = 0;
                }
                string key = "[" + serverUrl.Url + "]x[" + context.Request.UserHostAddress + "]";
                RateMeter rate;
                if (!ratemap.TryGetValue(key, out rate))
                {
                    rate = new RateMeter(serverUrl.RateLimit, serverUrl.RateLimitPeriod);
                    ratemap.TryAdd(key, rate);
                }
                if (!rate.click())
                {
                    log("[Warning]: Pair " + key + " is throttled to " + serverUrl.RateLimit + " requests per " + serverUrl.RateLimitPeriod + " minute(s). Come back later.");
                    response = HttpContext.Current.Response;
                    response.StatusCode = (int)System.Net.HttpStatusCode.PaymentRequired;
                    response.End();
                    return;
                }

                //making sure the rateMap gets periodaiclly cleaned up so it does not grow uncontrollably
                int cnt = (int)context.Application["rateMap_cleanup_counter"];
                cnt++;
                if (cnt >= CLEAN_RATEMAP_AFTER)
                {
                    cnt = 0;
                    cleanUpRatemap(ratemap);
                }
                context.Application["rateMap_cleanup_counter"] = cnt;
            }
        }

        //readying body (if any) of POST request
        byte[] postBody = readRequestPostBody(context);
        string post = System.Text.Encoding.UTF8.GetString(postBody);

        //if token comes with client request, it takes precedence over token or credentials stored in configuration
        bool hasClientToken = uri.Contains("?token=") || uri.Contains("&token=") || post.Contains("?token=") || post.Contains("&token=");
        string token = string.Empty;
        if (!passThrough && !hasClientToken) {
            // Get new token and append to the request.
            // But first, look up in the application scope, maybe it's already there:
            token = (String)context.Application["token_for_" + serverUrl.Url];
            bool tokenIsInApplicationScope = !String.IsNullOrEmpty(token);

            //if still no token, let's see if there are credentials stored in configuration which we can use to obtain new token
            if (!tokenIsInApplicationScope)
                token = getNewTokenIfCredentialsAreSpecified(serverUrl);

            if (!String.IsNullOrEmpty(token) && !tokenIsInApplicationScope) {
                //storing the token in Application scope, to do not waste time on requesting new one untill it expires or the app is restarted.
                context.Application.Lock();
                context.Application["token_for_" + serverUrl.Url] = token;
                context.Application.UnLock();
            }
        }

        //forwarding original request
        System.Net.WebResponse serverResponse = null;
        try {
            serverResponse = forwardToServer(context, addTokenToUri(uri, token), postBody);
        } catch (System.Net.WebException webExc) {
            response.StatusCode = 500;
            response.StatusDescription = webExc.Status.ToString();
            response.Write(webExc.Response);
            response.End();
            return;
        }

        if (passThrough || string.IsNullOrEmpty(token) || hasClientToken)
            //if token is not required or provided by the client, just fetch the response as is:
            fetchAndPassBackToClient(serverResponse, response, true);
        else {
            //credentials for secured service have come from configuration file:
            //it means that the proxy is responsible for making sure they were properly applied:

            //first attempt to send the request:
            bool tokenRequired = fetchAndPassBackToClient(serverResponse, response, false);


            //checking if previously used token has expired and needs to be renewed
            if (tokenRequired) {
                log("[Info]: Renewing token and trying again.");
                //server returned error - potential cause: token has expired.
                //we'll do second attempt to call the server with renewed token:
                token = getNewTokenIfCredentialsAreSpecified(serverUrl);
                serverResponse = forwardToServer(context, addTokenToUri(uri, token), postBody);

                //storing the token in Application scope, to do not waste time on requesting new one untill it expires or the app is restarted.
                context.Application.Lock();
                context.Application["token_for_" + serverUrl.Url] = token;
                context.Application.UnLock();

                fetchAndPassBackToClient(serverResponse, response, true);
            }
        }
        response.End();
    }

    public bool IsReusable {
        get { return true; }
    }

/**
* Private
*/
    private byte[] readRequestPostBody(HttpContext context) {
        if (context.Request.InputStream.Length > 0) {
            byte[] bytes = new byte[context.Request.InputStream.Length];
            context.Request.InputStream.Read(bytes, 0, (int)context.Request.InputStream.Length);
            return bytes;
        }
        return new byte[0];
    }

    private System.Net.WebResponse forwardToServer(HttpContext context, string uri, byte[] postBody) {
        return
            postBody.Length > 0?
            doHTTPRequest(uri, postBody, "POST", context.Request.Headers["referer"], context.Request.ContentType):
            doHTTPRequest(uri, context.Request.HttpMethod);
    }

    private bool fetchAndPassBackToClient(System.Net.WebResponse serverResponse, HttpResponse clientResponse, bool ignoreAuthenticationErrors) {
        if (serverResponse != null) {
            clientResponse.ContentType = serverResponse.ContentType;
            using (Stream byteStream = serverResponse.GetResponseStream()) {
                // Text response
                if (serverResponse.ContentType.Contains("text") ||
                    serverResponse.ContentType.Contains("json") ||
                    serverResponse.ContentType.Contains("xml")) {
                    using (StreamReader sr = new StreamReader(byteStream)) {
                        string strResponse = sr.ReadToEnd();
                        if (
                            !ignoreAuthenticationErrors
                            && strResponse.IndexOf("{\"error\":{") > -1
                            && (strResponse.IndexOf("\"code\":498") > -1 || strResponse.IndexOf("\"code\":499") > -1)
                        )
                            return true;
                        clientResponse.Write(strResponse);
                    }
                } else {
                    // Binary response (image, lyr file, other binary file)

                    // Tell client not to cache the image since it's dynamic
                    clientResponse.CacheControl = "no-cache";
                    byte[] buffer = new byte[32768];
                    int read;
                    while ((read = byteStream.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        clientResponse.OutputStream.Write(buffer, 0, read);
                    }
                    clientResponse.OutputStream.Close();
                }
                serverResponse.Close();
            }
        }
        return false;
    }

    private System.Net.WebResponse doHTTPRequest(string uri, string method) {
        byte[] bytes = null;
        String contentType = null;

        if (method.Equals("POST"))
        {
            String[] uriArray = uri.Split('?');

            if (uriArray.Length > 1)
            {
                contentType = "application/x-www-form-urlencoded";
                String queryString = uriArray[1];

                bytes = System.Text.Encoding.UTF8.GetBytes(queryString);
            }
        }

        return doHTTPRequest(uri, bytes, method, PROXY_REFERER, contentType);
    }

    private System.Net.WebResponse doHTTPRequest(string uri, byte[] bytes, string method, string referer, string contentType) {
        System.Net.HttpWebRequest req = (System.Net.HttpWebRequest)System.Net.HttpWebRequest.Create(uri);
        req.ServicePoint.Expect100Continue = false;
        req.Referer = referer;
        req.Method = method;
        if (bytes != null && bytes.Length > 0 || method == "POST") {
            req.Method = "POST";
            req.ContentType = string.IsNullOrEmpty(contentType) ? "application/x-www-form-urlencoded" : contentType;
            if (bytes != null && bytes.Length > 0)
                req.ContentLength = bytes.Length;
            using (Stream outputStream = req.GetRequestStream()) {
                outputStream.Write(bytes, 0, bytes.Length);
            }
        }
        return req.GetResponse();
    }

    private string webResponseToString(System.Net.WebResponse serverResponse) {
        using (Stream byteStream = serverResponse.GetResponseStream()) {
            using (StreamReader sr = new StreamReader(byteStream)) {
                string strResponse = sr.ReadToEnd();
                return strResponse;
            }
        }
    }

    private string getNewTokenIfCredentialsAreSpecified(ServerUrl su) {
        string token = "";
        bool isUserLogin = !String.IsNullOrEmpty(su.Username) && !String.IsNullOrEmpty(su.Password);
        bool isAppLogin = !String.IsNullOrEmpty(su.ClientId) && !String.IsNullOrEmpty(su.ClientSecret);
        if (isUserLogin || isAppLogin) {
            log("[Info]: Matching credentials found in config file. OAuth2 mode: " + isAppLogin);
            if (isAppLogin) {
                //OAuth 2.0 mode authentication
                //"App Login" - authenticating using client_id and client_secret stored in config
                su.OAuth2Endpoint = string.IsNullOrEmpty(su.OAuth2Endpoint) ? DEFAULT_OAUTH : su.OAuth2Endpoint;
                if (su.OAuth2Endpoint[su.OAuth2Endpoint.Length - 1] != '/')
                    su.OAuth2Endpoint += "/";
                log("[Info]: Service is secured by " + su.OAuth2Endpoint + ": getting new token...");
                string uri = su.OAuth2Endpoint + "token?client_id=" + su.ClientId + "&client_secret=" + su.ClientSecret + "&grant_type=client_credentials&f=json";
                string tokenResponse = webResponseToString(doHTTPRequest(uri, "POST"));
                token = extractToken(tokenResponse, "token");
                if (!string.IsNullOrEmpty(token))
                    token = exchangePortalTokenForServerToken(token, su);
            } else {
                //standalone ArcGIS Sevrer token-based authentication
                string infoUrl = su.Url.Substring(0, su.Url.ToLower().IndexOf("/rest"));
                if (infoUrl != "") {
                    log("[Info]: Querying security endpoint...");
                    infoUrl += "/rest/info?f=json";
                    string infoResponse = webResponseToString(doHTTPRequest(infoUrl, "GET"));
                    String tokenServiceUri = getJsonValue(infoResponse, "tokenServicesUrl");
                    if (string.IsNullOrEmpty(tokenServiceUri))
                        tokenServiceUri = getJsonValue(infoResponse, "tokenServiceUrl");
                    if (tokenServiceUri != "") {
                        log("[Info]: Service is secured by " + tokenServiceUri + ": getting new token...");
                        string uri = tokenServiceUri + "?f=json&request=getToken&referer=" + PROXY_REFERER + "&expiration=60&username=" + su.Username + "&password=" + su.Password;
                        string tokenResponse = webResponseToString(doHTTPRequest(uri, "POST"));
                        token = extractToken(tokenResponse, "token");
                    }
                }
            }
        }
        return token;
    }

    private string exchangePortalTokenForServerToken(string portalToken, ServerUrl su) {
        log("[Info]: Exchanging Portal token for Server-specific token for " + su.Url + "...");
        string uri = su.OAuth2Endpoint.Substring(0, su.OAuth2Endpoint.ToLower().IndexOf("/oauth2/")) +
             "/generateToken?token=" + portalToken + "&serverURL=" + su.Url + "&f=json";
        string tokenResponse = webResponseToString(doHTTPRequest(uri, "GET"));
        return extractToken(tokenResponse, "token");
    }

    private string addTokenToUri(string uri, string token) {
        if (!String.IsNullOrEmpty(token))
            uri += uri.Contains("?")? "&token=" + token : "?token=" + token;
        return uri;
    }

    private string extractToken(string tokenResponse, string key) {
        string token = getJsonValue(tokenResponse, key);
        if (string.IsNullOrEmpty(token))
            log("[Error]: Token cannot be obtained: " + tokenResponse);
        else
            log("[Info]: Token obtained: " + token);
        return token;
    }

    private string getJsonValue(string text, string key) {
        int i = text.IndexOf(key);
        String value = "";
        if (i > -1) {
            value = text.Substring(text.IndexOf(':', i) + 1).Trim();
            value = value.Length > 0 && value[0] == '"' ?
                value.Substring(1, value.IndexOf('"', 1) - 1):
                value = value.Substring(0, Math.Max(0, Math.Min(Math.Min(value.IndexOf(","), value.IndexOf("]")), value.IndexOf("}"))));
        }
        return value;
    }

    private void cleanUpRatemap(ConcurrentDictionary<string, RateMeter> ratemap) {
        foreach (string key in ratemap.Keys){
            RateMeter rate = ratemap[key];
            if (rate.canBeCleaned())
                ratemap.TryRemove(key, out rate);
        }
    }

/**
* Static
*/
    private static ProxyConfig getConfig() {
        ProxyConfig config = ProxyConfig.GetCurrentConfig();
        if (config != null)
            return config;
        else
            throw new ApplicationException("Proxy.config file does not exist at application root, or is not readable.");
    }

    //writing Log file
    private static TextWriter logFile;
    private static object _lockobject = new object();
    private static void log(string s) {
        try {
            string filename = "";
            bool okToLog = logFile != null;
            if (logFile == null) {
                filename = getConfig().LogFile;
                okToLog = !String.IsNullOrEmpty(filename);
            }
            lock (_lockobject) {
                if (okToLog) {
                    if (logFile == null)
                        logFile = new StreamWriter(filename);

                    logFile.WriteLine(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + s);
                    logFile.Flush();
                }
            }
        } catch (Exception) {/*can't write to the specified location?*/}
    }
}


[XmlRoot("ProxyConfig")]
public class ProxyConfig
{
    private static object _lockobject = new object();
    public static ProxyConfig LoadProxyConfig(string fileName) {
        ProxyConfig config = null;
        lock (_lockobject) {
            if (System.IO.File.Exists(fileName)) {
                XmlSerializer reader = new XmlSerializer(typeof(ProxyConfig));
                using (System.IO.StreamReader file = new System.IO.StreamReader(fileName)) {
                    config = (ProxyConfig)reader.Deserialize(file);
                }
            }
        }
        return config;
    }

    public static ProxyConfig GetCurrentConfig() {
        ProxyConfig config = HttpRuntime.Cache["proxyConfig"] as ProxyConfig;
        if (config == null) {
            string fileName = HttpContext.Current.Server.MapPath("~/proxy.config");
            config = LoadProxyConfig(fileName);
            if (config != null) {
                CacheDependency dep = new CacheDependency(fileName);
                HttpRuntime.Cache.Insert("proxyConfig", config, dep);
            }
        }
        return config;
    }

    ServerUrl[] serverUrls;
    bool mustMatch;
    string logFile;

    [XmlArray("serverUrls")]
    [XmlArrayItem("serverUrl")]
    public ServerUrl[] ServerUrls {
        get { return this.serverUrls; }
        set { this.serverUrls = value; }
    }
    [XmlAttribute("mustMatch")]
    public bool MustMatch {
        get { return mustMatch; }
        set { mustMatch = value; }
    }
    [XmlAttribute("logFile")]
    public string LogFile {
        get { return logFile; }
        set { logFile = value; }
    }

    public ServerUrl GetConfigServerUrl(string uri) {
        foreach (ServerUrl su in serverUrls)
            if (
                su.MatchAll && uri.StartsWith(su.Url, StringComparison.InvariantCultureIgnoreCase)
                || String.Compare(uri, su.Url, StringComparison.InvariantCultureIgnoreCase) == 0
             )
                return su;

        if (mustMatch)
            throw new InvalidOperationException();
        return null;
    }
}

public class ServerUrl {
    string url;
    bool matchAll;
    string oauth2Endpoint;
    string username;
    string password;
    string clientId;
    string clientSecret;
    string rateLimit;
    string rateLimitPeriod;

    [XmlAttribute("url")]
    public string Url {
        get { return url; }
        set { url = value; }
    }
    [XmlAttribute("matchAll")]
    public bool MatchAll {
        get { return matchAll; }
        set { matchAll = value; }
    }
    [XmlAttribute("oauth2Endpoint")]
    public string OAuth2Endpoint {
        get { return oauth2Endpoint; }
        set { oauth2Endpoint = value; }
    }
    [XmlAttribute("username")]
    public string Username {
        get { return username; }
        set { username = value; }
    }
    [XmlAttribute("password")]
    public string Password {
        get { return password; }
        set { password = value; }
    }
    [XmlAttribute("clientId")]
    public string ClientId {
        get { return clientId; }
        set { clientId = value; }
    }
    [XmlAttribute("clientSecret")]
    public string ClientSecret {
        get { return clientSecret; }
        set { clientSecret = value; }
    }
    [XmlAttribute("rateLimit")]
    public int RateLimit {
        get { return string.IsNullOrEmpty(rateLimit)? -1 : int.Parse(rateLimit); }
        set { rateLimit = value.ToString(); }
    }
    [XmlAttribute("rateLimitPeriod")]
    public int RateLimitPeriod {
        get { return string.IsNullOrEmpty(rateLimitPeriod)? 60 : int.Parse(rateLimitPeriod); }
        set { rateLimitPeriod = value.ToString(); }
    }
}
