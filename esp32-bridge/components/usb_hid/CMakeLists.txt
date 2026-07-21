# usb_hid/
idf_component_register(
    SRCS "usb_hid.c"
    INCLUDE_DIRS "include"
    REQUIRES "tinyusb"
)
