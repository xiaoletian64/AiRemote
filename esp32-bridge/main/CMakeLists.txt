# main/
idf_component_register(
    SRCS
        "main.c"
        "app_events.c"
        "app_fsm.c"
    INCLUDE_DIRS
        "."
    REQUIRES
        "ble_central"
        "usb_hid"
)
