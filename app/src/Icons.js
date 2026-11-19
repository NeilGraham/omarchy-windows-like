.pragma library

// Line icons as SVG path data on a 24 × 24 grid, drawn by Icon.qml.
var display = "M5 4h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z M9 21h6 M12 17v4"
var package_ = "M12 2.8l8 4.4v9.6l-8 4.4-8-4.4V7.2z M4 7.2l8 4.4 8-4.4 M12 11.6v9.6 M8 5l8 4.4"
var taskbar = "M5 4h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z M3 16h18 M8 18h2 M11 18h2 M14 18h2"
var snapping = "M5 4h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z M12 4v16 M12 12h9"
var tabs = "M3 10h18v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z M3 10V6a1 1 0 0 1 1-1h6v5 M10 5h5a1 1 0 0 1 1 1v4"
var search = "M10.5 4a6.5 6.5 0 1 1 0 13a6.5 6.5 0 1 1 0-13z M15.5 15.5l5 5"
var chevron = "M9 5l7 7-7 7"
var back = "M20 12H4 M10 6l-6 6 6 6"
var external = "M14 4h6v6 M20 4l-9 9 M19 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h4"
var info = "M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0-18z M12 11v6 M12 7.5v.5"

// This PC
var drive = "M3 14h18v5a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z M3 14l2.5-9h13L21 14 M17 17h.01"
var systemDrive = drive + " M10 7.5h1.6v1.6H10z M12.4 7.5H14v1.6h-1.6z M10 9.9h1.6v1.6H10z M12.4 9.9H14v1.6h-1.6z"
var usb = "M8 9h8v11a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1z M9.5 9V3h5v6 M11 5.5h.01 M13 5.5h.01"
var sdcard = "M7 3h7l4 4v13a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z M9 3v4 M11.5 3v4 M14 3.5V7"
var optical = "M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0-18z M12 9.5a2.5 2.5 0 1 1 0 5a2.5 2.5 0 1 1 0-5z"
var phone = "M8 2.5h8a1.5 1.5 0 0 1 1.5 1.5v16a1.5 1.5 0 0 1-1.5 1.5H8A1.5 1.5 0 0 1 6.5 20V4A1.5 1.5 0 0 1 8 2.5z M11 18.5h2"
var network = "M4 3h16a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z M17 7.5h.01 M12 12v5 M4 20h16 M12 17v3"
var folder = "M3 6a1 1 0 0 1 1-1h5l2 2h9a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z"
var documents = "M6 3h8l4 4v13a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z M14 3v4h4 M8.5 12h7 M8.5 15h7 M8.5 18h4"
var downloads = "M12 3v12 M7 10l5 5 5-5 M4 17v3h16v-3"
var music = "M9 18V5l11-2v13 M9 18a3 3 0 1 1-6 0a3 3 0 1 1 6 0z M20 16a3 3 0 1 1-6 0a3 3 0 1 1 6 0z"
var pictures = "M4 4h16a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z M3 16l5-5 5 5 3-3 5 5 M15.5 8.5h.01"
var videos = "M4 5h16a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1z M10 9v6l5-3z"
var refresh = "M20 12a8 8 0 1 1-2.3-5.7 M20 4v4.5h-4.5"
var close = "M6 6l12 12 M18 6L6 18"

// The icon for a This PC item (Drives' kind, or a folder's).
function forItem(item) {
    if (item.kind === "folder")
        return { desktop: display, documents: documents, downloads: downloads, music: music,
                 pictures: pictures, videos: videos }[item.folder] || folder
    return { system: systemDrive, usb: usb, sdcard: sdcard, optical: optical, phone: phone,
             network: network }[item.kind] || drive
}
