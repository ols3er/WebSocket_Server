﻿; ##################################################### License / Copyright #########################################
; 
;     The MIT License (MIT)
;     
;     Copyright (c) 2015 David Vogel
;     
;     Permission is hereby granted, free of charge, To any person obtaining a copy
;     of this software And associated documentation files (the "Software"), To deal
;     in the Software without restriction, including without limitation the rights
;     To use, copy, modify, merge, publish, distribute, sublicense, And/Or sell
;     copies of the Software, And To permit persons To whom the Software is
;     furnished To do so, subject To the following conditions:
;     
;     The above copyright notice And this permission notice shall be included in all
;     copies Or substantial portions of the Software.
;     
;     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS Or
;     IMPLIED, INCLUDING BUT Not LIMITED To THE WARRANTIES OF MERCHANTABILITY,
;     FITNESS For A PARTICULAR PURPOSE And NONINFRINGEMENT. IN NO EVENT SHALL THE
;     AUTHORS Or COPYRIGHT HOLDERS BE LIABLE For ANY CLAIM, DAMAGES Or OTHER
;     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT Or OTHERWISE, ARISING FROM,
;     OUT OF Or IN CONNECTION With THE SOFTWARE Or THE USE Or OTHER DEALINGS IN THE
;     SOFTWARE.
; 
; #################################################### Documentation ################################################
; 
; #### WebSocket_Server ####
; 
; Enable Threadsafe!
; 
; - Works in unicode and ascii mode
; - Works under x86 and x64
; 
; Working OSes:
; - Windows
;   - Tested: 7 x64
; - Linux
;   - Not tested yet
; - MacOS
;   - Not tested yet
; 
; 
; 
; Version history:
; - V0.990 (05.02.2015)
;   - Everything done (Hopefully)
; 
; - V0.991 (09.02.2015)
;   - Changed endian conversion from bitshifting to direct memory access to make the include working with x86.
; 
; - V0.992 (09.02.2015)
;   - Added #Frame_Payload_Max to prevent clients to make the server allocate a lot of memory.
;   - Some other small bugfixes.
; 
; - V0.993 (24.10.2015)
;   - Made it compatible with PB 5.40 LTS (Mainly SHA-1)
;   - Bugfix with pokes

; ##################################################### Check Compiler options ######################################

CompilerIf Not #PB_Compiler_Thread
  CompilerError "Thread-Safe is not activated!"
CompilerEndIf

; ##################################################### Module ######################################################

DeclareModule WebSocket_Server
  
  ; ##################################################### Public Constants ############################################
  
  #Version = 0993
  
  Enumeration
    #Event_None
    #Event_Connect
    #Event_Disconnect
    #Event_Frame
  EndEnumeration
  
  Enumeration
    #Opcode_Continuation
    #Opcode_Text
    #Opcode_Binary
    
    #Opcode_Connection_Close = 8
    #Opcode_Ping
    #Opcode_Pong
  EndEnumeration
  
  #RSV1 = %00000100
  #RSV2 = %00000010
  #RSV3 = %00000001
  
  #Frame_Payload_Max = 10000000  ; Max-Size of a incoming frames payload. If the frame exceeds this value, the client will be disconnected
  
  ; ##################################################### Public Structures ###########################################
  
  Structure Event_Frame
    Fin.a                 ; #True if this is the final frame of a series of frames
    RSV.a                 ; Extension bits: RSV1, RSV2, RSV3
    Opcode.a              ; Opcode
    
    *Payload
    Payload_Size.i
  EndStructure
  
  ; ##################################################### Public Variables ############################################
  
  ; ##################################################### Public Prototypes ###########################################
  
  Prototype   Event_Callback(*Object, *Client, Event.i, *Custom_Structure=#Null)
  
  ; ##################################################### Public Procedures (Declares) ################################
  
  Declare.i Create(Port, *Event_Thread_Callback.Event_Callback=#Null, Frame_Payload_Max.q=#Frame_Payload_Max) ; Creates a new WebSocket server. *Event_Thread_Callback is the callback which will be called out of the server thread.
  Declare   Free(*Object)                                                                   ; Closes the WebSocket server
  
  Declare   Frame_Text_Send(*Object, *Client, Text.s)                                       ; Sends a text-frame
  Declare   Frame_Send(*Object, *Client, FIN.a, RSV.a, Opcode.a, *Payload, Payload_Size.q)  ; Sends a frame. FIN, RSV and Opcode can be freely defined. Normally you should use #Opcode_Binary
   
  Declare   Event_Callback(*Object, *Callback.Event_Callback)                               ; Checks for events, and calls the *Callback function if there are any.
  
  Declare   Client_Disconnect(*Object, *Client)                                             ; Disconnects the specified *Client
  
EndDeclareModule

; ##################################################### Module (Private Part) #######################################

Module WebSocket_Server
  
  EnableExplicit
  
  InitNetwork()
  UseSHA1Fingerprint()
  
  ; ##################################################### Constants ###################################################
  
  #Frame_Data_Size_Min = 2048
  
  #HTTP_Header_Data_Size_Step = 2048
  
  #GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  
  Enumeration
    #Mode_Handshake
    #Mode_Frames
  EndEnumeration
  
  ; ##################################################### Structures ##################################################
  
  Structure Eight_Bytes
    Byte.a[8]
  EndStructure
  
  Structure HTTP_Header
    *Data
    
    RX_Pos.i
    
    Request.s
    Map Field.s()
  EndStructure
  
  Structure Frame_Header_Length
    Dummy.a
    Length.a
    Extended.a[8]
  EndStructure
  
  Structure Frame_Header
    StructureUnion
      Byte.a[14]            ; Size of the header is 14B max.
      Length.Frame_Header_Length
    EndStructureUnion
  EndStructure
  
  Structure Frame
    *Data.Frame_Header
    
    RxTx_Pos.i              ; Current position while receiving or sending the frame
    RxTx_Size.i             ; Size of the frame (Header + Payload)
    
    Payload_Pos.i
    Payload_Size.q          ; Quad, because a frame can be 2^64B large.
    
    Done.l                  ; #True --> All data sent or received
  EndStructure
  
  Structure Client
    ID.i                    ; Client ID. Is #Null when the connection closes but there are still incoming frames left.
    
    HTTP_Header.HTTP_Header
    
    List RX_Frame.Frame()   ; Incoming frames
    List TX_Frame.Frame()   ; Outgoing frames
    
    Mode.i
    
    Event.i
    
    External_Reference.i    ; #True --> An external reference was given to the application (via event). If the connection closes, there must be a closing event.
    
    Close.i                 ; #True --> Close connection as soon as all data is sent and all received data is read by the application. (The server-side sets this flag)
  EndStructure
  
  Structure Object
    Server_ID.i
    Thread_ID.i
    
    List Client.Client()
    
    *Event_Thread_Callback.Event_Callback
    
    Frame_Payload_Max.q     ; Max-Size of a incoming frames payload. If the frame exceeds this value, the client will be disconnected
    
    Mutex.i
    
    Free.i
  EndStructure
  
  ; ##################################################### Variables ###################################################
  
  ; ##################################################### Procedures ##################################################
  
  Procedure Client_Select(*Object.Object, ID.i)
    If Not ID
      ProcedureReturn #False
    EndIf
    
    ForEach *Object\Client()
      If *Object\Client()\ID = ID
        ProcedureReturn #True
      EndIf
    Next
    
    ProcedureReturn #False
  EndProcedure
  
  Procedure.s Generate_Key(Client_Key.s)
    Protected *Temp_Data_2, *Temp_Data_3
    Protected Temp_String.s
    Protected Temp_SHA1.s
    Protected i
    Protected Result.s
    
    Temp_String.s = Client_Key + #GUID
    
    ; #### Generate the SHA1
    *Temp_Data_2 = AllocateMemory(20)
    Temp_SHA1.s = StringFingerprint(Temp_String, #PB_Cipher_SHA1, 0, #PB_Ascii)
    Debug Temp_SHA1
    For i = 0 To 19
      PokeA(*Temp_Data_2+i, Val("$"+Mid(Temp_SHA1, 1+i*2, 2)))
    Next
    
    ; #### Encode the SHA1 as Base64
    *Temp_Data_3 = AllocateMemory(30)
    Base64Encoder(*Temp_Data_2, 20, *Temp_Data_3, 30)
    
    Result = PeekS(*Temp_Data_3, -1, #PB_Ascii)
    
    FreeMemory(*Temp_Data_2)
    FreeMemory(*Temp_Data_3)
    
    ProcedureReturn Result
  EndProcedure
  
  Procedure Thread_Receive_Handshake(*Object.Object, *Client.Client)
    Protected Result.i
    Protected *Temp_Data
    Protected Temp_Text.s
    Protected Temp_Line.s
    Protected Temp_Key.s
    Protected Response.s
    Protected i
    
    Repeat
      
      ; #### Manage memory
      If Not *Client\HTTP_Header\Data
        *Client\HTTP_Header\Data = AllocateMemory(#HTTP_Header_Data_Size_Step)
      EndIf
      If MemorySize(*Client\HTTP_Header\Data) < *Client\HTTP_Header\RX_Pos + 1
        *Temp_Data = ReAllocateMemory(*Client\HTTP_Header\Data, (*Client\HTTP_Header\RX_Pos / #HTTP_Header_Data_Size_Step + 1) * #HTTP_Header_Data_Size_Step)
        If *Temp_Data
          *Client\HTTP_Header\Data = *Temp_Data
        Else
          ProcedureReturn #False
        EndIf
      EndIf
      
      ; #### Receive one byte
      Result = ReceiveNetworkData(*Client\ID, *Client\HTTP_Header\Data + *Client\HTTP_Header\RX_Pos, 1)
      If Result > 0
        *Client\HTTP_Header\RX_Pos + Result
      ElseIf Result = 0
        Break
      Else
        Debug "WebSocket_Server Error: ReceiveNetworkData() returns " + Str(Result)
        ProcedureReturn #False
      EndIf
      
      ; #### Check if the header ends
      If *Client\HTTP_Header\RX_Pos >= 4
        If PeekL(*Client\HTTP_Header\Data + *Client\HTTP_Header\RX_Pos - 4) = 168626701 ; ### CR LF CR LF
          
          Temp_Text = PeekS(*Client\HTTP_Header\Data, *Client\HTTP_Header\RX_Pos-2, #PB_Ascii)
          
          *Client\HTTP_Header\Request = StringField(Temp_Text, 1, #CRLF$)
          
          For i = 2 To CountString(Temp_Text, #CRLF$)
            Temp_Line = StringField(Temp_Text, i, #CRLF$)
            *Client\HTTP_Header\Field(StringField(Temp_Line, 1, ":")) = Trim(StringField(Temp_Line, 2, ":"))
          Next
          
          ; #### Check if the request is correct
          ;TODO: Check if this mess works with most clients/browsers!
          If StringField(*Client\HTTP_Header\Request, 1, " ") = "GET"
            If *Client\HTTP_Header\Field("Upgrade") = "websocket"
              If FindString(*Client\HTTP_Header\Field("Connection"), "Upgrade")
                If Val(*Client\HTTP_Header\Field("Sec-WebSocket-Version")) = 13 And FindMapElement(*Client\HTTP_Header\Field(), "Sec-WebSocket-Key")
                  *Client\Mode = #Mode_Frames
                  *Client\Event = #Event_Connect
                  Response = "HTTP/1.1 101 Switching Protocols" + #CRLF$ +
                             "Upgrade: websocket" + #CRLF$ +
                             "Connection: Upgrade" + #CRLF$ +
                             "Sec-WebSocket-Accept: " + Generate_Key(*Client\HTTP_Header\Field("Sec-WebSocket-Key")) + #CRLF$ +
                             #CRLF$
                Else
                  *Client\Close = #True
                  Response = "HTTP/1.1 400 Bad Request" + #CRLF$ +
                             "Content-Type: text/html" + #CRLF$ +
                             "Content-Length: 63" + #CRLF$ +
                             #CRLF$ +
                             "<html><head></head><body><h1>400 Bad Request</h1></body></html>"
                EndIf
              Else
                *Client\Close = #True
                Response = "HTTP/1.1 400 WebSocket Upgrade Failure" + #CRLF$ +
                           "Content-Type: text/html" + #CRLF$ +
                           "Content-Length: 77" + #CRLF$ +
                           #CRLF$ +
                           "<html><head></head><body><h1>400 WebSocket Upgrade Failure</h1></body></html>"
              EndIf
            Else
              *Client\Close = #True
              Response = "HTTP/1.1 404 Not Found" + #CRLF$ +
                         "Content-Type: text/html" + #CRLF$ +
                         "Content-Length: 61" + #CRLF$ +
                         #CRLF$ +
                         "<html><head></head><body><h1>404 Not Found</h1></body></html>"
            EndIf
          Else
            *Client\Close = #True
            Response = "HTTP/1.1 405 Method Not Allowed" + #CRLF$ +
                       "Content-Type: text/html" + #CRLF$ +
                       "Content-Length: 70" + #CRLF$ +
                       #CRLF$ +
                       "<html><head></head><body><h1>405 Method Not Allowed</h1></body></html>"
          EndIf
          
          ; #### Misuse a frame for the HTTP response
          LastElement(*Client\TX_Frame())
          If AddElement(*Client\TX_Frame())
            
            *Client\TX_Frame()\RxTx_Size = StringByteLength(Response, #PB_Ascii)
            *Client\TX_Frame()\Data = AllocateMemory(*Client\TX_Frame()\RxTx_Size)
            
            PokeS(*Client\TX_Frame()\Data, Response, -1, #PB_Ascii | #PB_String_NoZero)
            
          EndIf
          
          Break
        EndIf
      EndIf
      
    ForEver
    
    ProcedureReturn #True
  EndProcedure
  
  Procedure Thread_Receive_Frame(*Object.Object, *Client.Client)
    Protected Receive_Size.i
    Protected Result.i
    Protected *Temp_Data
    Protected Mask.l, *Pointer_Mask.Long
    Protected *Eight_Bytes.Eight_Bytes
    Protected i
    
    If *Client\Close
      ProcedureReturn #False
    EndIf
    
    If ListSize(*Client\RX_Frame()) = 0
      AddElement(*Client\RX_Frame())
      *Client\RX_Frame()\RxTx_Size = 2
    EndIf
    
    While LastElement(*Client\RX_Frame())
      
      ; #### Add new element if the current element is received completely.
      If *Client\RX_Frame()\Done
        AddElement(*Client\RX_Frame())
        *Client\RX_Frame()\RxTx_Size = 2
      EndIf
      
      ; #### Check if the frame exceeds the max. frame-size
      If *Client\RX_Frame()\Payload_Size > *Object\Frame_Payload_Max
        *Client\Close = #True
        Break
      EndIf
      
      ;TODO: Make this simliar to the allocation in Thread_Receive_Handshake()
      ; #### Manage memory
      If Not *Client\RX_Frame()\Data
        *Client\RX_Frame()\Data = AllocateMemory(#Frame_Data_Size_Min)
      EndIf
      If MemorySize(*Client\RX_Frame()\Data) < *Client\RX_Frame()\RxTx_Size + 3                   ; #### Add 3 bytes so that the (de)masking doesn't write outside of the buffer
        *Temp_Data = ReAllocateMemory(*Client\RX_Frame()\Data, *Client\RX_Frame()\RxTx_Size + 3)
        If *Temp_Data
          *Client\RX_Frame()\Data = *Temp_Data
        Else
          FreeMemory(*Client\RX_Frame()\Data)
          DeleteElement(*Client\RX_Frame())
          *Client\Close = #True
          ProcedureReturn #False
        EndIf
      EndIf
      
      ; #### Calculate how many bytes needs to be received
      Receive_Size = *Client\RX_Frame()\RxTx_Size - *Client\RX_Frame()\RxTx_Pos
      
      ; #### Receive...
      Result = ReceiveNetworkData(*Client\ID, *Client\RX_Frame()\Data + *Client\RX_Frame()\RxTx_Pos, Receive_Size)
      If Result > 0
        *Client\RX_Frame()\RxTx_Pos + Result
      Else
        Break
      EndIf
      
      ; #### Recalculate the size of the current frame (Only if all data is received)
      If *Client\RX_Frame()\RxTx_Pos >= *Client\RX_Frame()\RxTx_Size
        
        ; #### Size of the first 2 byte in the header
        *Client\RX_Frame()\RxTx_Size = 2
        
        ; #### Determine the length of the payload
        Select *Client\RX_Frame()\Data\Length\Length & %01111111
          Case 0 To 125
            *Client\RX_Frame()\Payload_Size = *Client\RX_Frame()\Data\Length\Length & %01111111
            
          Case 126
            *Client\RX_Frame()\RxTx_Size + 2
            If *Client\RX_Frame()\RxTx_Pos = *Client\RX_Frame()\RxTx_Size
              *Eight_Bytes = @*Client\RX_Frame()\Payload_Size
              *Eight_Bytes\Byte[1] = *Client\RX_Frame()\Data\Length\Extended[0]
              *Eight_Bytes\Byte[0] = *Client\RX_Frame()\Data\Length\Extended[1]
            EndIf
            
          Case 127
            *Client\RX_Frame()\RxTx_Size + 8
            If *Client\RX_Frame()\RxTx_Pos = *Client\RX_Frame()\RxTx_Size
              *Eight_Bytes = @*Client\RX_Frame()\Payload_Size
              *Eight_Bytes\Byte[7] = *Client\RX_Frame()\Data\Length\Extended[0]
              *Eight_Bytes\Byte[6] = *Client\RX_Frame()\Data\Length\Extended[1]
              *Eight_Bytes\Byte[5] = *Client\RX_Frame()\Data\Length\Extended[2]
              *Eight_Bytes\Byte[4] = *Client\RX_Frame()\Data\Length\Extended[3]
              *Eight_Bytes\Byte[3] = *Client\RX_Frame()\Data\Length\Extended[4]
              *Eight_Bytes\Byte[2] = *Client\RX_Frame()\Data\Length\Extended[5]
              *Eight_Bytes\Byte[1] = *Client\RX_Frame()\Data\Length\Extended[6]
              *Eight_Bytes\Byte[0] = *Client\RX_Frame()\Data\Length\Extended[7]
            EndIf
            
        EndSelect
        
        If *Client\RX_Frame()\RxTx_Pos >= *Client\RX_Frame()\RxTx_Size
          
          ; #### Add the payload length to the size of the framedata
          *Client\RX_Frame()\RxTx_Size + *Client\RX_Frame()\Payload_Size
          
          ; #### Check if there is a mask
          If *Client\RX_Frame()\Data\Byte[1] & %10000000
            *Client\RX_Frame()\RxTx_Size + 4
          EndIf
          
          *Client\RX_Frame()\Payload_Pos = *Client\RX_Frame()\RxTx_Size - *Client\RX_Frame()\Payload_Size
          
        EndIf
        
      EndIf
      
      ; #### Check if the frame is received completely
      If *Client\RX_Frame()\RxTx_Pos >= *Client\RX_Frame()\RxTx_Size
        
        ; #### (De)masking
        If *Client\RX_Frame()\Data\Byte[1] & %10000000
          ; #### Get mask
          Mask = PeekL(*Client\RX_Frame()\Data + *Client\RX_Frame()\Payload_Pos - 4)
          
          ; #### XOr mask
          *Pointer_Mask = *Client\RX_Frame()\Data + *Client\RX_Frame()\Payload_Pos
          For i = 0 To *Client\RX_Frame()\Payload_Size-1 Step 4
            *Pointer_Mask\l = *Pointer_Mask\l ! Mask
            *Pointer_Mask + 4
          Next
          
        EndIf
        
        ; #### Frame is done and can be forwarded to the application
        *Client\RX_Frame()\Done = #True
        
        ; #### Check type of frame, and delete it if it shouldn't be forwarded.
        Select *Object\Client()\RX_Frame()\Data\Byte[0] & %00001111
          Case #Opcode_Continuation       ; continuation frame
          Case #Opcode_Text               ; text frame
          Case #Opcode_Binary             ; binary frame
          Case #Opcode_Connection_Close   ; connection close
            ;FreeMemory(*Client\RX_Frame()\Data)
            ;DeleteElement(*Client\RX_Frame())
            *Client\Close = #True
          Case #Opcode_Ping               ; ping
            Frame_Send(*Object, *Client, #True, 0, #Opcode_Pong, *Client\RX_Frame()\Data + *Client\RX_Frame()\Payload_Pos, *Client\RX_Frame()\Payload_Size)
            ;FreeMemory(*Client\RX_Frame()\Data)
            ;DeleteElement(*Client\RX_Frame())
          Case #Opcode_Pong               ; pong
          Default                         ; undefined
            Frame_Send(*Object, *Client, #True, 0, #Opcode_Connection_Close, #Null, 0)
            ;FreeMemory(*Client\RX_Frame()\Data)
            ;DeleteElement(*Client\RX_Frame())
            *Client\Close = #True
        EndSelect
        
        Break
      EndIf
      
    Wend
    
    ProcedureReturn #True
  EndProcedure
  
  Procedure Thread_Transmit(*Object.Object, *Client.Client)
    Protected Transmit_Size.i
    Protected Result.i
    
    While FirstElement(*Client\TX_Frame())
      
      Transmit_Size = *Client\TX_Frame()\RxTx_Size - *Client\TX_Frame()\RxTx_Pos
      
      If Transmit_Size > 0
        ; #### Some data needs to be sent
        Result = SendNetworkData(*Client\ID, *Client\TX_Frame()\Data + *Client\TX_Frame()\RxTx_Pos, Transmit_Size)
        If Result > 0
          *Client\TX_Frame()\RxTx_Pos + Result
        Else
          Break
        EndIf
      EndIf
      
      Transmit_Size = *Client\TX_Frame()\RxTx_Size - *Client\TX_Frame()\RxTx_Pos
      
      If Transmit_Size <= 0
        ; #### Frame can be deleted
        FreeMemory(*Client\TX_Frame()\Data)
        DeleteElement(*Client\TX_Frame())
      EndIf
      
    Wend
    
    ProcedureReturn #True
  EndProcedure
  
  Procedure Thread(*Object.Object)
    Repeat
      
      ; #### Network Events
      Select NetworkServerEvent(*Object\Server_ID)
        Case #PB_NetworkEvent_None
          Delay(10)
          
        Case #PB_NetworkEvent_Connect
          LockMutex(*Object\Mutex)
          LastElement(*Object\Client())
          AddElement(*Object\Client())
          *Object\Client()\ID = EventClient()
          UnlockMutex(*Object\Mutex)
          
        Case #PB_NetworkEvent_Disconnect
          LockMutex(*Object\Mutex)
          If Client_Select(*Object, EventClient())
            *Object\Client()\ID = #Null ; #### Client will be deleted later. The application can still read all incoming frames.
            *Object\Client()\Event = #Event_Disconnect
          EndIf
          UnlockMutex(*Object\Mutex)
          
        Case #PB_NetworkEvent_Data
          LockMutex(*Object\Mutex)
          If Client_Select(*Object, EventClient())
            Select *Object\Client()\Mode
              Case #Mode_Handshake  : Thread_Receive_Handshake(*Object, *Object\Client())
              Case #Mode_Frames     : Thread_Receive_Frame(*Object, *Object\Client())
            EndSelect
          EndIf
          UnlockMutex(*Object\Mutex)
          
      EndSelect
      
      ; #### Event Callback (Threaded)
      If *Object\Event_Thread_Callback
        Event_Callback(*Object, *Object\Event_Thread_Callback)
      EndIf
      
      ; #### Send Data
      LockMutex(*Object\Mutex)
      ForEach *Object\Client()
        If *Object\Client()\ID
          Thread_Transmit(*Object, *Object\Client())
        EndIf
      Next
      UnlockMutex(*Object\Mutex)
      
    Until *Object\Free
    
    CloseNetworkServer(*Object\Server_ID) : *Object\Server_ID = #Null
    
    ForEach *Object\Client()
      ; #### Free all RX_Frames()
      ForEach *Object\Client()\RX_Frame()
        FreeMemory(*Object\Client()\RX_Frame()\Data)
      Next
      
      ; #### Free all TX_Frames()
      ForEach *Object\Client()\TX_Frame()
        FreeMemory(*Object\Client()\TX_Frame()\Data)
      Next
    Next
    
    FreeStructure(*Object)
  EndProcedure
  
  Procedure Frame_Send(*Object.Object, *Client.Client, FIN.a, RSV.a, Opcode.a, *Payload, Payload_Size.q)
    Protected *Pointer.Ascii
    Protected *Eight_Bytes.Eight_Bytes
    
    If Not *Object
      ProcedureReturn #False
    EndIf
    
    If Not *Client
      ProcedureReturn #False
    EndIf
    
    If Not *Client\ID Or *Client\Close
      ProcedureReturn #False
    EndIf
    
    If Payload_Size < 0
      ProcedureReturn #False
    EndIf
    
    If Not *Payload
      Payload_Size = 0
    EndIf
    
    LockMutex(*Object\Mutex)
    
    LastElement(*Client\TX_Frame())
    If AddElement(*Client\TX_Frame())
      
      *Client\TX_Frame()\Data = AllocateMemory(10 + Payload_Size)
      
      ; #### FIN, RSV and Opcode
      *Pointer = *Client\TX_Frame()\Data
      *Pointer\a = (FIN & 1) << 7 | (RSV & %111) << 4 | (Opcode & %1111) : *Pointer + 1
      *Client\TX_Frame()\RxTx_Size + 1
      
      ; #### Payload_Size and extended stuff
      Select Payload_Size
        Case 0 To 125
          *Pointer\a = Payload_Size       : *Pointer + 1
          *Client\TX_Frame()\RxTx_Size + 1
        Case 126 To 65536
          *Eight_Bytes = @Payload_Size
          *Pointer\a = 126                  : *Pointer + 1
          *Pointer\a = *Eight_Bytes\Byte[1] : *Pointer + 1
          *Pointer\a = *Eight_Bytes\Byte[0] : *Pointer + 1
          *Client\TX_Frame()\RxTx_Size + 3
        Default
          *Eight_Bytes = @Payload_Size
          *Pointer\a = 127                  : *Pointer + 1
          *Pointer\a = *Eight_Bytes\Byte[7] : *Pointer + 1
          *Pointer\a = *Eight_Bytes\Byte[6] : *Pointer + 1
          *Pointer\a = *Eight_Bytes\Byte[5] : *Pointer + 1
          *Pointer\a = *Eight_Bytes\Byte[4] : *Pointer + 1
          *Pointer\a = *Eight_Bytes\Byte[3] : *Pointer + 1
          *Pointer\a = *Eight_Bytes\Byte[2] : *Pointer + 1
          *Pointer\a = *Eight_Bytes\Byte[1] : *Pointer + 1
          *Pointer\a = *Eight_Bytes\Byte[0] : *Pointer + 1
          *Client\TX_Frame()\RxTx_Size + 9
      EndSelect
      
      If *Payload
        CopyMemory(*Payload, *Pointer, Payload_Size)
        ;*Pointer + Payload_Size
        *Client\TX_Frame()\RxTx_Size + Payload_Size
      EndIf
      
    EndIf
    
    UnlockMutex(*Object\Mutex)
    
    ProcedureReturn #True
  EndProcedure
  
  Procedure Frame_Text_Send(*Object.Object, *Client.Client, Text.s)
    Protected *Temp, Temp_Size.i
    Protected Result
    
    Temp_Size = StringByteLength(Text, #PB_UTF8)
    If Temp_Size <= 0
      ProcedureReturn #False
    EndIf
    *Temp = AllocateMemory(Temp_Size)
    If Not *Temp
      ProcedureReturn #False
    EndIf
    
    PokeS(*Temp, Text, -1, #PB_UTF8 | #PB_String_NoZero)
    
    Result = Frame_Send(*Object, *Client, #True, 0, #Opcode_Text, *Temp, Temp_Size)
    
    FreeMemory(*Temp)
    
    ProcedureReturn Result
  EndProcedure
  
  Procedure Event_Callback(*Object.Object, *Callback.Event_Callback)
    Protected Event_Frame.Event_Frame
    
    If Not *Object
      ProcedureReturn #False
    EndIf
    
    If Not *Callback
      ProcedureReturn #False
    EndIf
    
    LockMutex(*Object\Mutex)
    
    ;TODO: Rework how the events are handled internally, right now it's too hackish.
    
    ForEach *Object\Client()
      
      Select *Object\Client()\Event
        Case #Event_Connect
          ; #### Event: Client connected and handshake was successful
          *Object\Client()\Event = #Event_None
          *Object\Client()\External_Reference = #True
          *Callback(*Object, *Object\Client(), #Event_Connect)
          UnlockMutex(*Object\Mutex)
          ProcedureReturn #True
          
        Case #Event_Disconnect
          ; #### Event: Client disconnected
          ; #### Only return this event if there are no incoming frames left.
          If ListSize(*Object\Client()\RX_Frame()) = 0
            *Object\Client()\Event = #Event_None
            *Callback(*Object, *Object\Client(), #Event_Disconnect)
            ; #### Free all TX_Frames()
            ForEach *Object\Client()\TX_Frame()
              FreeMemory(*Object\Client()\TX_Frame()\Data)
            Next
            DeleteElement(*Object\Client())
            UnlockMutex(*Object\Mutex)
            ProcedureReturn #True
          EndIf
          
      EndSelect
      
      ; #### Event: Close connection (Initiated by the server-side)
      If *Object\Client()\Close
        ; #### Only close the connection if there are no frames left.
        If ListSize(*Object\Client()\TX_Frame()) = 0; And ListSize(*Object\Client()\RX_Frame()) = 0
          ; #### Forward event to application, but only if there was a connect event for this client before
          If *Object\Client()\External_Reference
            *Callback(*Object, *Object\Client(), #Event_Disconnect)
          EndIf
          ; #### Free all RX_Frames()
          ForEach *Object\Client()\RX_Frame()
            FreeMemory(*Object\Client()\RX_Frame()\Data)
          Next
          CloseNetworkConnection(*Object\Client()\ID)
          DeleteElement(*Object\Client())
          UnlockMutex(*Object\Mutex)
          ProcedureReturn #True
        EndIf
      EndIf
      
      ; #### Event: Frame available
      If FirstElement(*Object\Client()\RX_Frame())
        If *Object\Client()\RX_Frame()\Done
          Event_Frame\Fin = *Object\Client()\RX_Frame()\Data\Byte[0] >> 7 & %00000001
          Event_Frame\RSV = *Object\Client()\RX_Frame()\Data\Byte[0] >> 4 & %00000111
          Event_Frame\Opcode = *Object\Client()\RX_Frame()\Data\Byte[0] & %00001111
          Event_Frame\Payload = *Object\Client()\RX_Frame()\Data + *Object\Client()\RX_Frame()\Payload_Pos
          Event_Frame\Payload_Size = *Object\Client()\RX_Frame()\Payload_Size
          
          *Callback(*Object, *Object\Client(), #Event_Frame, Event_Frame)
          
          FreeMemory(*Object\Client()\RX_Frame()\Data)
          DeleteElement(*Object\Client()\RX_Frame())
          
          UnlockMutex(*Object\Mutex)
          ProcedureReturn #True
        EndIf
      EndIf
      
    Next
    
    UnlockMutex(*Object\Mutex)
    ProcedureReturn #False
  EndProcedure
  
  Procedure Client_Disconnect(*Object.Object, *Client.Client)
    If Not *Object
      ProcedureReturn #False
    EndIf
    
    If Not *Client
      ProcedureReturn #False
    EndIf
    
    Frame_Send(*Object, *Client, 1, 0, #Opcode_Connection_Close, #Null, 0)
    
    *Client\Close = #True
    
    ProcedureReturn #True
  EndProcedure
  
  Procedure Create(Port, *Event_Thread_Callback.Event_Callback=#Null, Frame_Payload_Max.q=#Frame_Payload_Max)
    Protected *Object.Object
    
    *Object = AllocateStructure(Object)
    If Not *Object
      ProcedureReturn #Null
    EndIf
    
    *Object\Mutex = CreateMutex()
    If Not *Object\Mutex
      FreeStructure(*Object)
      ProcedureReturn #Null
    EndIf
    
    *Object\Server_ID = CreateNetworkServer(#PB_Any, Port, #PB_Network_TCP)
    If Not *Object\Server_ID
      FreeMutex(*Object\Mutex)
      FreeStructure(*Object)
      ProcedureReturn #Null
    EndIf
    
    *Object\Thread_ID = CreateThread(@Thread(), *Object)
    If Not *Object\Thread_ID
      FreeMutex(*Object\Mutex)
      CloseNetworkServer(*Object\Server_ID)
      FreeStructure(*Object)
      ProcedureReturn #Null
    EndIf
    
    *Object\Frame_Payload_Max = Frame_Payload_Max
    *Object\Event_Thread_Callback = *Event_Thread_Callback
    
    ProcedureReturn *Object
  EndProcedure
  
  Procedure Free(*Object.Object)
    If Not *Object
      ProcedureReturn #False
    EndIf
    
    *Object\Free = #True
    
    ProcedureReturn #True
  EndProcedure
  
EndModule

; IDE Options = PureBasic 5.40 LTS (Windows - x64)
; CursorPosition = 239
; FirstLine = 54
; Folding = ---
; EnableUnicode
; EnableThread
; EnableXP
; EnablePurifier = 1,1,1,1