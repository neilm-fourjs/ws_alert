#+ API
#+ /alert/<type>/<message> - raise an alert
#+ /status  - just return the status of the alert service
#+ /maint/start/<reason>  - service into maintenance mode - alerts are ignored
#+ /maint/stop  - service back to normal
#+ /exit  - just exit the service

IMPORT com
IMPORT FGL g2_lib
IMPORT FGL g2_logging
IMPORT FGL g2_db

PUBLIC DEFINE g2_log g2_logging.logger
PUBLIC DEFINE m_controller VARCHAR(254)
----------------------------------------------------------------------------------------------------
-- Initialize the service - Start the log and connect to database.
PUBLIC FUNCTION init()
  DEFINE l_db g2_db.dbInfo
  CALL g2_log.init(NULL, NULL, "log", "TRUE")
  WHENEVER ANY ERROR CALL g2_lib.g2_error
  CALL l_db.g2_connect(NULL)
  LET m_controller = fgl_getEnv("HOSTNAME")
  IF LENGTH(m_controller) < 2 THEN
    LET m_controller = "localhost"
  END IF
  CALL chkTables()
  RUN "env | sort > /tmp/gas.env"
  CALL g2_log.logIt("Service Initialized.")
  RETURN TRUE
END FUNCTION
----------------------------------------------------------------------------------------------------
-- Start the service loop
PUBLIC FUNCTION start()
  DEFINE l_ret SMALLINT
  DEFINE l_msg STRING

  CALL com.WebServiceEngine.RegisterRestService("ws_alert_funcs", "AlertService")

  LET l_msg = SFMT("Service started on '%1'.", m_controller)
  CALL com.WebServiceEngine.Start()
  WHILE TRUE
    CALL g2_log.logIt(SFMT("Service: %1", l_msg))
    LET l_ret = com.WebServiceEngine.ProcessServices(-1)
    CASE l_ret
      WHEN 0
        LET l_msg = "Request processed."
      WHEN -1
        LET l_msg = "Timeout reached."
      WHEN -2
        LET l_msg = "Disconnected from application server."
        EXIT WHILE # The Application server has closed the connection
      WHEN -3
        LET l_msg = "Client Connection lost."
      WHEN -4
        LET l_msg = "Server interrupted with Ctrl-C."
      WHEN -9
        LET l_msg = "Unsupported operation."
      WHEN -10
        LET l_msg = "Internal server error."
      WHEN -23
        LET l_msg = "Deserialization error."
      WHEN -35
        LET l_msg = "No such REST operation found."
      WHEN -36
        LET l_msg = "Missing REST parameter."
      OTHERWISE
        LET l_msg = SFMT("Unexpected server error %1.", l_ret)
        EXIT WHILE
    END CASE
    IF int_flag != 0 THEN
      LET l_msg = "Service interrupted."
      LET int_flag = 0
      EXIT WHILE
    END IF
  END WHILE
  CALL g2_log.logIt(SFMT("Server stopped: %1", l_msg))

END FUNCTION
----------------------------------------------------------------------------------------------------
-- Just exit the service
PUBLIC FUNCTION exit(
    ) ATTRIBUTES(WSGet, WSPath = "/exit", WSDescription = "Exit the service")
    RETURNS STRING
  CALL g2_log.logIt("Server stopped by 'exit' call")
  RETURN serivce_reply("Service Stopped.")
END FUNCTION
----------------------------------------------------------------------------------------------------
-- Return the status of the service
PUBLIC FUNCTION status(
    ) ATTRIBUTES(WSGet, WSPath = "/status", WSDescription = "Returns status of service")
    RETURNS STRING
  DEFINE l_reply STRING
  DEFINE l_stat CHAR(1)
  DEFINE l_statDesc VARCHAR(40)
  DEFINE l_date DATE
  DEFINE l_time DATETIME HOUR TO SECOND
-- check the status in the database
  TRY
    SELECT state, state_desc, last_update_on, last_update_at
        INTO l_stat, l_statDesc, l_date, l_time
        FROM alert_status
        WHERE controller_name = m_controller
  CATCH
  END TRY
  IF STATUS != 0 THEN
    LET l_reply = sql_error("select", STATUS, SQLERRMESSAGE)
    RETURN l_reply
  END IF

  CASE l_stat
    WHEN "O"
      LET l_reply = SFMT("Okay: %1: %2 %3", l_statDesc, l_date, l_time)
    WHEN "M"
      LET l_reply = SFMT("Maintenance mode: %1: %2 %3", l_statDesc, l_date, l_time)
    OTHERWISE
      LET l_reply = SFMT("Unknown '%1':%2: %3 %4", l_stat, l_statDesc, l_date, l_time)
  END CASE
  CALL g2_log.logIt(l_reply)
  RETURN serivce_reply(l_reply)
END FUNCTION
----------------------------------------------------------------------------------------------------
-- Add an alert to the alert table
PUBLIC FUNCTION alert(
    l_type STRING ATTRIBUTES(WSParam), l_message STRING ATTRIBUTES(WSParam))
    ATTRIBUTES(WSGet,
        WSPath = "/alert/{l_type}/{l_message}",
        WSDescription = "Returns status of service")
    RETURNS STRING
  DEFINE l_reply STRING
  DEFINE l_stat CHAR(1)
  DEFINE l_machine VARCHAR(254)
  DEFINE l_date DATE
  DEFINE l_time DATETIME HOUR TO SECOND

  TRY
    SELECT state INTO l_stat FROM alert_status WHERE controller_name = m_controller
  CATCH
  END TRY
  IF STATUS != 0 THEN
    LET l_reply = sql_error("select", STATUS, SQLERRMESSAGE)
    CALL g2_log.logIt(l_reply)
    RETURN l_reply
  END IF

  IF l_stat = "M" THEN
    LET l_reply = "Alert ignored due to maintenance mode."
    CALL g2_log.logIt(l_reply)
    RETURN l_reply
  END IF

  LET l_reply = SFMT("Alert Processed: %1 %2", l_type, l_message)
  LET l_date = TODAY
  LET l_time = TIME
  LET l_machine = fgl_getEnv("")
  IF LENGTH(l_machine CLIPPED) < 2 THEN
    LET l_machine = "unknown"
  END IF
  TRY
    INSERT INTO alert_messages VALUES(l_machine, l_type, l_message, l_date, l_time)
  CATCH
  END TRY
  IF STATUS != 0 THEN
    LET l_reply = sql_error("insert", STATUS, SQLERRMESSAGE)
  END IF
  CALL g2_log.logIt(l_reply)
  RETURN serivce_reply(l_reply)
END FUNCTION
----------------------------------------------------------------------------------------------------
-- Start Maintenance Mode.
PUBLIC FUNCTION maintStart(
    l_reason STRING ATTRIBUTES(WSParam))
    ATTRIBUTES(WSGet,
        WSPath = "/maint/start/{l_reason}",
        WSDescription = "Returns status of service")
    RETURNS STRING
  DEFINE l_reply STRING
  DEFINE l_date DATE
  DEFINE l_time DATETIME HOUR TO SECOND
  LET l_reply = "Okay - Maintenace Mode Started"
  LET l_date = TODAY
  LET l_time = TIME

-- Update the status in the database
  TRY
    UPDATE alert_status
        SET (state, state_desc, last_update_on, last_update_at)
        = ("M", l_reason, l_date, l_time)
        WHERE controller_name = m_controller
  CATCH
  END TRY
  IF STATUS != 0 THEN
    LET l_reply = sql_error("update", STATUS, SQLERRMESSAGE)
  END IF
  CALL g2_log.logIt(l_reply)
  RETURN serivce_reply(l_reply)
END FUNCTION
----------------------------------------------------------------------------------------------------
-- Stop Maintenance Mode.
PUBLIC FUNCTION maintStop(
    ) ATTRIBUTES(WSGet,
        WSPath = "/maint/stop",
        WSDescription = "Take service out of maintenace mode.")
    RETURNS STRING
  DEFINE l_reply STRING
  DEFINE l_date DATE
  DEFINE l_time DATETIME HOUR TO SECOND
  LET l_reply = "Okay - Maintenace Mode Stopped"
  LET l_date = TODAY
  LET l_time = TIME
-- Update the status in the database
  TRY
    UPDATE alert_status
        SET (state, state_desc, last_update_on, last_update_at)
        = ("O", "Okay", l_date, l_time)
        WHERE controller_name = m_controller
  CATCH
  END TRY
  IF STATUS != 0 THEN
    LET l_reply = sql_error("update", STATUS, SQLERRMESSAGE)
  END IF
  CALL g2_log.logIt(l_reply)
  RETURN serivce_reply(l_reply)
END FUNCTION

----------------------------------------------------------------------------------------------------
-- Format the string reply from the service function
PRIVATE FUNCTION serivce_reply(l_reply STRING) RETURNS STRING
  LET l_reply = SFMT("%1:%2:%3:%4:%5", m_controller, fgl_getPID(), TODAY, TIME, l_reply)
  RETURN l_reply
END FUNCTION
----------------------------------------------------------------------------------------------------
-- Format the sql error message.
PRIVATE FUNCTION sql_error(l_stmt STRING, l_stat SMALLINT, l_err STRING) RETURNS STRING
  DEFINE l_reply STRING
  LET l_reply = SFMT("DB '%1' error on '%1': %2 %3", l_stmt, m_controller, l_stat, l_err)
  RETURN l_reply
END FUNCTION
----------------------------------------------------------------------------------------------------
-- Check the required tables exist and create if not.
PRIVATE FUNCTION chkTables()
  DEFINE l_date DATE
  DEFINE l_time DATETIME HOUR TO SECOND
  LET l_date = TODAY
  LET l_time = TIME
  TRY
--		DROP TABLE alert_status
    SELECT COUNT(*) FROM alert_status
  CATCH
  END TRY
  IF STATUS != 0 THEN
    DISPLAY "Status:", STATUS, ":", SQLERRMESSAGE
    CREATE TABLE alert_status(
        controller_name VARCHAR(254),
        state CHAR(1),
        state_desc VARCHAR(40),
        last_update_on DATE,
        last_update_at DATETIME HOUR TO SECOND)
    CREATE UNIQUE INDEX ifx_alert_stat1 ON alert_status(controller_name)
  END IF

  DISPLAY SFMT("Insert status if doesn't exist for '%1'", m_controller)
  SELECT * FROM alert_status WHERE controller_name = m_controller
  IF STATUS = NOTFOUND THEN
    INSERT INTO alert_status VALUES(m_controller, "O", "Initalized", l_date, l_time)
    DISPLAY SFMT("Inserted status for '%1'", m_controller)
  END IF

  TRY
--		DROP TABLE alert_messages
    SELECT * FROM alert_messages
  CATCH
    IF STATUS != 0 THEN
      DISPLAY "Status:", STATUS, ":", SQLERRMESSAGE
      CREATE TABLE alert_messages(
          machine_name VARCHAR(254),
          alert_type VARCHAR(20),
          message VARCHAR(254),
          recieved_on DATE,
          recieved_at DATETIME HOUR TO SECOND)
    END IF
  END TRY
END FUNCTION
