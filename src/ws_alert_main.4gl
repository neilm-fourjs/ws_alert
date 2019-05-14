#+ A simple restfull api for handling an alert message
#+ neilm@4js.com

-- The web service functions
IMPORT FGL ws_alert_funcs

MAIN

  IF NOT ws_alert_funcs.init() THEN
    EXIT PROGRAM
  END IF

  CALL ws_alert_funcs.start()

END MAIN
