/** @license
 | Version 10.1.1
 | Copyright 2012 Esri
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
var searchAddress;

//function to locate address
function LocateAddress() {
    noRoute = false;
    ShowProgressIndicator();
    if (dojo.byId("txtAddress").value.trim() == '') {
        HideProgressIndicator();
        alert(messages.getElementsByTagName("addressToLocate")[0].childNodes[0].nodeValue);
        dojo.byId('txtAddress').value = "";
        dojo.byId('txtAddress').focus();
        return;
    }
    var address = [];
    address[locatorFields[0]] = dojo.byId('txtAddress').value;

    var locator1 = new esri.tasks.Locator(locatorURL);
    locator1.outSpatialReference = map.spatialReference;
    locator1.addressToLocations(address, ["Loc_name"], function (candidates) {
        ShowLocatedAddress(candidates);
    },
    function (err) {
        HideProgressIndicator();
        dojo.byId('txtAddress').value = "";
        dojo.byId('txtAddress').focus();
        selectedPollPoint = null;
        alert(messages.getElementsByTagName("unableToLocate")[0].childNodes[0].nodeValue);
    });
}

//function to populate address
function ShowLocatedAddress(candidates) {
    RemoveChildren(dojo.byId('tblAddressResults'));
    CreateScrollbar(dojo.byId("divAddressScrollContainer"), dojo.byId("divAddressScrollContent"));

    if (candidates.length > 0) {
        if (candidates[0].score == 100) {
            HideProgressIndicator();
            dojo.byId('txtAddress').setAttribute("defaultAddress", candidates[0].address);
            mapPoint = new esri.geometry.Point(candidates[0].location.x, candidates[0].location.y, map.spatialReference);
            LocateAddressOnMap(true);
        }
        else {
            var table = dojo.byId("tblAddressResults");
            var tBody = document.createElement("tbody");
            table.appendChild(tBody);
            table.cellSpacing = 0;
            table.cellPadding = 0;
            for (var i = 0; i < candidates.length; i++) {
                var candidate = candidates[i];
                var tr = document.createElement("tr");
                tBody.appendChild(tr);
                var td1 = document.createElement("td");
                td1.innerHTML = candidate.address;
                td1.align = "left";
                td1.className = 'bottomborder';
                td1.style.cursor = "pointer";
                td1.height = 20;
                td1.setAttribute("x", candidate.location.x);
                td1.setAttribute("y", candidate.location.y);
                td1.setAttribute("address", candidate.address);
                td1.onclick = function () {
                    dojo.byId("txtAddress").value = this.innerHTML;
                    dojo.byId('txtAddress').setAttribute("defaultAddress", this.innerHTML);
                    mapPoint = new esri.geometry.Point(this.getAttribute("x"), this.getAttribute("y"), map.spatialReference);
                    LocateAddressOnMap(true);
                }
                tr.appendChild(td1);
            }
            HideProgressIndicator();
            SetHeightAddressResults();
        }
    }
    else {
        HideProgressIndicator();
        dojo.byId('txtAddress').focus();
        map.infoWindow.hide();
        selectedPollPoint = null;
        pollPoint = null;
        mapPoint = null;
        ClearSelection();
        map.getLayer(tempGraphicsLayerId).clear();
        map.getLayer(precinctLayerId).clear();
        map.getLayer(routeGraphicsLayerId).clear();
        map.getLayer(highlightPollLayerId).clear();
        if (!isMobileDevice) {
            var imgToggle = dojo.byId('imgToggleResults');
            if (imgToggle.getAttribute("state") == "maximized") {
                imgToggle.setAttribute("state", "minimized");
                WipeOutResults();
                dojo.byId('imgToggleResults').src = "images/up.png";
                dojo.byId('imgToggleResults').title = "Show Panel";
            }
        }
        alert(messages.getElementsByTagName("unableToLocate")[0].childNodes[0].nodeValue);
    }
}

//function to locate address on map
function LocateAddressOnMap(loc) {
    map.infoWindow.hide();
    ClearGraphics();
    if (!map.getLayer(precinctLayerId).fullExtent.contains(mapPoint)) {
        map.infoWindow.hide();
        selectedPollPoint = null;
        pollPoint = null;
        mapPoint = null;
        ClearSelection();
        map.getLayer(tempGraphicsLayerId).clear();
        map.getLayer(precinctLayerId).clear();
        map.getLayer(routeGraphicsLayerId).clear();
        map.getLayer(highlightPollLayerId).clear();
        if (!isMobileDevice) {
            var imgToggle = dojo.byId('imgToggleResults');
            if (imgToggle.getAttribute("state") == "maximized") {
                imgToggle.setAttribute("state", "minimized");
                WipeOutResults();
                dojo.byId('imgToggleResults').src = "images/up.png";
            }
        }
        HideProgressIndicator();
        HideAddressContainer();
        alert(messages.getElementsByTagName("noDataAvlbl")[0].childNodes[0].nodeValue);
        return;
    }
    if (loc) {
        var symbol = new esri.symbol.PictureMarkerSymbol(locatorMarkupSymbolPath, 25, 25);
        var graphic = new esri.Graphic(mapPoint, symbol, null, null);
        map.getLayer(tempGraphicsLayerId).add(graphic);
    }
    else {
        var locator2 = new esri.tasks.Locator(locatorURL);
        locator2.locationToAddress(mapPoint, 100);
        dojo.connect(locator2, "onLocationToAddressComplete", function (candidate) {
            if (candidate.address) {
                var symbol = new esri.symbol.PictureMarkerSymbol(locatorMarkupSymbolPath, 25, 25);
                var attr = [];
                if (candidate.address.Loc_name == "US_Zipcode") {
                    attr = { Address: candidate.address.Zip };
                }
                else {
                    var address = [];
                    for (var att in locatorFields) {
                        address.push(candidate.address[locatorFields[att]]);
                    }
                    attr = { Address: address.join(',') };
                }

                var graphic = new esri.Graphic(mapPoint, symbol, attr, null);
                map.getLayer(tempGraphicsLayerId).add(graphic);
            }
        });
    }
    FindPrecinctLayer();
    if (!isMobileDevice) {
        ShowPollingPlaceDetails();
        for (var index in electedOfficialsTabData) {
            GetOfficeName(electedOfficialsTabData[index].URL, electedOfficialsTabData[index].Data, index);
        }
    }
    HideAddressContainer();
}

