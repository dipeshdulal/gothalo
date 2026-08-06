/// Native platforms release the camera when the scanner controller is
/// disposed; only the web build needs the extra shove (see the web variant).
void releaseCameraStreams() {}
