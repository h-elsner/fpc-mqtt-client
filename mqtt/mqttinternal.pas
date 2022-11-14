{ MQTT client internal data structures and procedures

  Copyright (C) 2022 Bernd Kreuß prof7bit@gmail.com

  This library is free software; you can redistribute it and/or modify it
  under the terms of the GNU Library General Public License as published by
  the Free Software Foundation; either version 2 of the License, or (at your
  option) any later version with the following modification:

  As a special exception, the copyright holders of this library give you
  permission to link this library with independent modules to produce an
  executable, regardless of the license terms of these independent modules,and
  to copy and distribute the resulting executable under terms of your choice,
  provided that you also meet, for each linked independent module, the terms
  and conditions of the license of that module. An independent module is a
  module which is not derived from or based on this library. If you modify
  this library, you may extend this exception to your version of the library,
  but you are not obligated to do so. If you do not wish to do so, delete this
  exception statement from your version.

  This program is distributed in the hope that it will be useful, but WITHOUT
  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE. See the GNU Library General Public License
  for more details.

  You should have received a copy of the GNU Library General Public License
  along with this library; if not, write to the Free Software Foundation,
  Inc., 51 Franklin Street - Fifth Floor, Boston, MA 02110-1335, USA.
}
unit mqttinternal;

{$mode ObjFPC}{$H+}
{$ModeSwitch arrayoperators}
{$PackEnum 1}
{$PackSet 1}

interface

uses
  Classes, SysUtils;

type
  EMQTTProtocolError = class(Exception);
  EMQTTMalformedInteger = class(EMQTTProtocolError);
  EMQTTUnexpectedProperty = class(EMQTTProtocolError);

  TMQTTPacketType = (
    // Ch. 2.1.2
    mqptReserved    = 0,
    mqptConnect     = 1,
    mqptConnAck     = 2,
    mqptPublish     = 3,
    mqptPubAck      = 4,
    mqptPubRec      = 5,
    mqptPubRel      = 6,
    mqptPubComp     = 7,
    mqptSubscribe   = 8,
    mqptSubAck      = 9,
    mqptUnsubscribe = 10,
    mqptUnsubAck    = 11,
    mqptPingReq     = 12,
    mqptPingResp    = 13,
    mqptDisconnect  = 14,
    mqptAuth        = 15
  );

  TStringPair = record
    Key: UTF8String;
    Value: UTF8String;
  end;

  { TMQTTParsedPacket }

  TMQTTParsedPacket = class
    PacketType: TMQTTPacketType;
    PacketFlags: Byte;
    Remaining: TMemoryStream;
    constructor Create(AType: TMQTTPacketType; AFlags: Byte; ARemaining: TMemoryStream);
    destructor Destroy; override;
    procedure Parse; virtual;
    function DebugPrint(FromStart: Boolean): String;
  end;


  { TMQTTConnAck }

  TMQTTConnAck = class(TMQTTParsedPacket) // Ch. 3.2
    ConnAckFlags: Byte;
    ReasonCode: Byte;
    ExpiryInterval: UInt32;
    RecvMax: UInt16;
    MaxQoS: Byte;
    RetainAvail: Boolean;
    MaxPackSize: UInt32;
    ClientID: UTF8String;
    TopicAliasMax: Byte;
    ReasonString: UTF8String;
    UserProperty: array of TStringPair;
    WildSubsAvail: Boolean;
    SubsIdentAvail: Boolean;
    SharedSubsAvail: Boolean;
    ServerKeepalive: UInt16;
    ResponseInfo: UTF8String;
    ServerRef: UTF8String;
    AuthMeth: UTF8String;
    AuthData: TBytes;
    procedure Parse; override;
  end;

  TMQTTPingResp = class(TMQTTParsedPacket) // Ch. 3.13
    // contains no data
  end;

  { TMQTTSubAck }

  TMQTTSubAck = class(TMQTTParsedPacket) // Ch. 3.9
    PacketID: UInt16;
    ReasonString: UTF8String;
    UserProperty: array of TStringPair;
    ReasonCodes: array of Byte;
    procedure Parse; override;
  end;

  { TMQTTPublish }

  TMQTTPublish = class(TMQTTParsedPacket) // Ch. 3.3
    Dup: Boolean;
    QoS: Byte;
    Retain: Boolean;
    TopicName: UTF8String;
    PacketID: UInt16;
    PayloadFormat: Byte;
    ExpiryInterval: UInt32;
    TopicAlias: UInt16;
    RespTopic: UTF8String;
    CorrelData: TBytes;
    UserProperty: array of TStringPair;
    SubscriptionID: array of UInt32;
    ContentType: UTF8String;
    Message: String;
    procedure Parse; override;
  end;

  { TMQTTStream }

  TMQTTStream = class helper for TStream
    procedure WriteVarInt(X: UInt32);
    procedure WriteInt16Big(X: UInt16);
    procedure WriteInt32Big(X: UInt32);
    procedure WriteMQTTString(X: UTF8String);
    procedure WriteMQTTBin(X: TBytes);
    procedure WriteMQTTPacket(Typ: TMQTTPacketType; Flags: Byte; Remaining: TMemoryStream);
    procedure WriteMQTTConnect(ID, User, Pass: string; Keepalive: UInt16);
    procedure WriteMQTTPingReq;
    procedure WriteMQTTSubscribe(Topic: String; PacketID: UInt16; SubsID: UInt32);
    procedure WriteMQTTPublish(Topic, Message, ResponseTopic: String; CorrelData: TBytes; PacketID: UInt16; QoS: Byte; Retain: Boolean);

    function ReadVarInt: UInt32;
    function ReadInt16Big: UInt16;
    function ReadInt32Big: UInt32;
    function ReadMQTTString: UTF8String;
    function ReadMQTTBin: TBytes;
    function ReadMQTTPacket: TMQTTParsedPacket;
  end;


implementation

{ TMQTTPublish }

procedure TMQTTPublish.Parse;
var
  PropLen: UInt32;
  PropEnd: UInt32;
  Prop: Byte;
  SP: TStringPair;
begin
  Retain := Boolean(PacketFlags and %0001);
  QoS := (PacketFlags and %0110) shr 1;
  Dup := Boolean(PacketFlags and %1000);
  with Remaining do begin
    TopicName := ReadMQTTString;                  // Ch. 3.3.2.1
    if QoS > 0 then
      PacketID := ReadInt16Big;                   // Ch. 3.3.2.2

    // begin properties
    PropLen := ReadVarInt;                        // Ch. 3.3.2.3.1
    PropEnd := Position + PropLen;
    while Position < PropEnd do begin
      Prop := ReadByte;
      case Prop of
        01: PayloadFormat := ReadByte;            // Ch. 3.3.2.3.2
        02: ExpiryInterval := ReadInt32Big;       // Ch. 3.3.2.3.3
        35: TopicAlias := ReadInt16Big;           // Ch. 3.3.2.3.4
        08: RespTopic := ReadMQTTString;          // Ch. 3.3.2.3.5
        09: CorrelData := ReadMQTTBin;            // Ch. 3.3.2.3.6
        38: begin                                 // Ch. 3.3.2.3.7
          SP.Key := ReadMQTTString;
          SP.Value := ReadMQTTString;
          UserProperty += [SP];
        end;
        11: SubscriptionID += [ReadVarInt];       // Ch. 3.3.2.3.8
        03: ContentType := ReadMQTTString;        // Ch. 3.3.2.3.9
      else
        raise EMQTTUnexpectedProperty.Create(Format('unexpected prop %d in PUBLISH package', [Prop]));
      end;
    end;
    // end properties

    // begin payload
    SetLength(Message, Size - Position);
    ReadBuffer(Message[1], Size - Position);
    // end payload
  end;
end;

{ TMQTTSubAck }

procedure TMQTTSubAck.Parse;
var
  PropLen: UInt32;
  PropEnd: UInt32;
  Prop: Byte;
  SP: TStringPair;
begin
  with Remaining do begin
    PacketID := ReadInt16Big;                     // Ch. 3.9.2

    // begin properties
    PropLen := ReadVarInt;                        // Ch. 3.9.2.1.1
    PropEnd := Position + PropLen;
    while Position < PropEnd do begin
      Prop := ReadByte;
      case Prop of
        31: ReasonString := ReadMQTTString;       // Ch. 3.9.2.1.2
        38: begin                                 // Ch. 3.9.2.1.3
          SP.Key := ReadMQTTString;
          SP.Value := ReadMQTTString;
          UserProperty += [SP];
        end;
        else
          raise EMQTTUnexpectedProperty.Create(Format('unexpected prop %d in SUBACK package', [Prop]));
      end;
    end;
    // end properties

    // begin payload                              // Ch. 3.9.3
    while Position < Size do begin
      ReasonCodes += [ReadByte];
    end;
    // end payload
  end;
end;

{ TMQTTConnAck }

procedure TMQTTConnAck.Parse;
var
  PropLen: UInt32;
  PropEnd: UInt32;
  Prop: Byte;
  SP: TStringPair;
begin
  // Ch. 3.2
  with Remaining do begin
    ConnAckFlags := ReadByte;                      // Ch. 3.2.2.1
    ReasonCode := ReadByte;                        // Ch. 3.2.2.2
    // begin properties
    PropLen := ReadVarInt;                         // Ch. 3.2.2.3.1
    PropEnd := Position + PropLen;
    // defaults
    RecvMax := $ffff;
    MaxQoS := 2;
    RetainAvail := True;
    MaxPackSize := High(MaxPackSize);
    WildSubsAvail := True;
    SubsIdentAvail := True;
    SharedSubsAvail := True;
    ServerKeepalive := High(ServerKeepalive);
    while Position < PropEnd do begin
      Prop := ReadByte;
      case Prop of
        17: ExpiryInterval := ReadInt32Big;        // Ch. 3.2.2.3.2
        33: RecvMax := ReadInt16Big;               // Ch. 3.2.2.3.3
        36: MaxQoS := ReadByte;                    // Ch. 3.2.2.3.4
        37: RetainAvail := Boolean(ReadByte);      // Ch. 3.2.2.3.5
        39: MaxPackSize := ReadInt32Big;           // Ch. 3.2.2.3.6
        18: ClientID := ReadMQTTString;            // Ch. 3.2.2.3.7
        34: TopicAliasMax := ReadInt16Big;         // Ch. 3.2.2.3.8
        31: ReasonString := ReadMQTTString;        // Ch. 3.2.2.3.9
        38: begin                                  // Ch. 3.2.2.3.10
          SP.Key := ReadMQTTString;
          SP.Value := ReadMQTTString;
          UserProperty += [SP];
        end;
        40: WildSubsAvail := Boolean(ReadByte);    // Ch. 3.2.2.3.11
        41: SubsIdentAvail := Boolean(ReadByte);   // Ch. 3.2.2.3.12
        42: SharedSubsAvail :=  Boolean(ReadByte); // Ch. 3.2.2.3.13
        19: ServerKeepalive := ReadInt16Big;       // Ch. 3.2.2.3.14
        26: ResponseInfo := ReadMQTTString;        // Ch. 3.2.2.3.15
        28: ServerRef := ReadMQTTString;           // Ch. 3.2.2.3.16
        21: AuthMeth := ReadMQTTString;            // Ch. 3.2.2.3.17
        22: AuthData := ReadMQTTBin;               // Ch. 3.2.2.3.18
      else
        raise EMQTTUnexpectedProperty.Create(Format('unexpected prop %d in CONNACK package', [Prop]));
      end;
    end;
    // end properties
    // no payload
  end;
end;

{ TMQTTParsedPacket }

constructor TMQTTParsedPacket.Create(AType: TMQTTPacketType; AFlags: Byte; ARemaining: TMemoryStream);
begin
  inherited Create;
  Remaining := ARemaining;
  Remaining.Seek(0, soBeginning);
  PacketType := AType;
  PacketFlags := AFlags;
  Parse;
end;

destructor TMQTTParsedPacket.Destroy;
begin
  Remaining.Free;
  inherited Destroy;
end;

procedure TMQTTParsedPacket.Parse;
begin
  // empty default implementation, do nothing.
end;

function TMQTTParsedPacket.DebugPrint(FromStart: Boolean): String;
begin
  Result := '';
  if FromStart then
     Remaining.Seek(0, soBeginning);
  while Remaining.Position < Remaining.Size do begin
    Result += IntToHex(Remaining.ReadByte, 2) + ' ';
  end;
  Remaining.Seek(0, soBeginning);
end;

{ TMQTTStream }

procedure TMQTTStream.WriteVarInt(X: UInt32);
var
  EncodedByte: Byte;
begin
  // Ch. 1.5.5
  repeat
    EncodedByte := X and $7f;
    X := X shr 7;
    if X > 0 then
       EncodedByte := EncodedByte or $80;
    WriteByte(EncodedByte);
  until X = 0;
end;

procedure TMQTTStream.WriteInt16Big(X: UInt16);
begin
  // Ch. 1.5.2
  WriteByte(X shr 8);
  WriteByte(X);
end;

procedure TMQTTStream.WriteInt32Big(X: UInt32);
begin
  // Ch. 1.5.3
  WriteByte(X shr 24);
  WriteByte(X shr 16);
  WriteByte(X shr 8);
  WriteByte(X);
end;

procedure TMQTTStream.WriteMQTTString(X: UTF8String);
var
  L: UInt16;
begin
  // Ch. 1.5.4
  L := Length(X);
  WriteInt16Big(L);
  WriteBuffer(X[1], L); // traditionally strings have 1-based indices in Pascal
end;

procedure TMQTTStream.WriteMQTTBin(X: TBytes);
var
  L: UInt16;
begin
  // Ch. 1.5.6
  L := Length(X);
  WriteInt16Big(L);
  WriteBuffer(X[0], L);
end;

procedure TMQTTStream.WriteMQTTPacket(Typ: TMQTTPacketType; Flags: Byte; Remaining: TMemoryStream);
begin
  // each packet has a fixed header                             (Ch. 2.1.1)
  WriteByte((ord(Typ) shl 4) or Flags);

  // folowed by a variable header,                              (Ch. 2.2)
  // and optionally a payload                                   (Ch. 2.3)

  if Assigned(Remaining) then begin
    // The second element of the fixed header is a variable int
    // length field which counts the number of all remaining bytes
    // until the end of the packet.
    WriteVarInt(Remaining.Size);  // byte 2..                   (Ch. 2.1.4)

    // Everything after that variable int field until the end has
    // already been prepared in the 'Remaining' memory stream object
    // and we append it here. After this the packet will be complete.
    Remaining.Seek(0, soBeginning);
    CopyFrom(Remaining, Remaining.Size);
  end
  else
    WriteVarInt(0); // a packet without data, remaining length = 0
end;

procedure TMQTTStream.WriteMQTTConnect(ID, User, Pass: string; Keepalive: UInt16);
type
  TConnectFlag = (          // Ch. 3.1.2.3
    cfReserved0   = 0,
    cfCleanStart  = 1,      // Ch. 3.1.2.4
    cfWill        = 2,      // Ch. 3.1.2.5
    cfWillQoS1    = 3,      // Ch. 3.1.2.6
    cfWillQoS2    = 4,      // Ch. 3.1.2.6
    cfWillRetain  = 5,      // Ch. 3.1.2.7
    cfPass        = 6,      // Ch. 3.1.2.9
    cfUser        = 7       // Ch. 3.1.2.8
  );

var
  Remaining: TMemoryStream;
  ConnectFlags: Set of TConnectFlag;
begin
  ConnectFlags := [cfCleanStart, cfUser, cfPass];

  // Ch. 3.1.2
  Remaining := TMemoryStream.Create;
  with Remaining do begin
    WriteMQTTString('MQTT');                  // byte 1..6        (Ch. 3.1.2.1)
    WriteByte(5);                             // version          (Ch. 3.1.2.2)
    WriteByte(Byte(ConnectFlags));            // connect flags    (Ch. 3.1.2.3)
    WriteInt16Big(Keepalive);                 // keepalive        (Ch. 3.1.2.10)

    // begin properties                                           (Ch. 3.1.2.11)
    WriteVarInt(3);                           // length           (Ch. 3.1.2.11.1)
    WriteByte(34);                            // Topic Alias Max  (Ch. 3.1.2.11.5)
    WriteInt16Big($ffff);
    // end properties

    // begin payload                                              (Ch. 3.1.3)
    WriteMQTTString(ID);                      // client id        (Ch. 3.1.3.1)
    // no will properties                                         (Ch. 3.1.3.2)
    // no will topic                                              (Ch. 3.1.3.3)
    // no will payload                                            (Ch. 3.1.3.4)
    WriteMQTTString(User);                    // username         (Ch. 3.1.3.5)
    WriteMQTTString(Pass);                    // password         (Ch. 3.1.3.6)
    // end payload
  end;

  // write an MQTT packet with fixed header and remaining data
  WriteMQTTPacket(mqptConnect, 0, Remaining);
  Remaining.Free;
end;

procedure TMQTTStream.WriteMQTTPingReq;
begin
  // Ch. 3.12
  WriteMQTTPacket(mqptPingReq, 0, nil);
end;

procedure TMQTTStream.WriteMQTTSubscribe(Topic: String; PacketID: UInt16; SubsID: UInt32);
var
  Remaining: TMemoryStream;
  Props: TMemoryStream;
begin
  // Ch. 3.8
  Remaining := TMemoryStream.Create;
  with Remaining do begin
    WriteInt16Big(PacketID);                  // bytes 1..2       (Ch. 3.8.2)

    // begin props                            //                  (Ch. 3.8.2.1)
    Props := TMemoryStream.Create;
    Props.WriteByte(11);                      // subcription ID   (Ch. 3.8.2.1.2)
    Props.WriteVarInt(SubsID);
    Props.Seek(0, soBeginning);
    WriteVarInt(Props.Size);                  // props length     (Ch. 3.8.2.1.1)
    CopyFrom(Props, Props.size);
    Props.Free;
    // end props

    // begin payload
    WriteMQTTString(Topic);                   //                  (Ch. 3.8.3)
    WriteByte(%00000000);                     // subs-opt         (Ch. 3.8.3.1)
    // end payload
  end;

  // write an MQTT packet with fixed header and remaining data
  WriteMQTTPacket(mqptSubscribe, %0010, Remaining);
  Remaining.Free;
end;

procedure TMQTTStream.WriteMQTTPublish(Topic, Message, ResponseTopic: String; CorrelData: TBytes; PacketID: UInt16; QoS: Byte; Retain: Boolean);
var
  Remaining: TMemoryStream;
  Props: TMemoryStream;
  Flags: Byte = 0;
begin
  // Ch. 3.8

  Flags := Flags or ((QoS and %11) << 1);
  if Retain then
    Flags := Flags or 1;

  Remaining := TMemoryStream.Create;
  with Remaining do begin
    WriteMQTTString(Topic);
    if QoS > 0 then
       WriteInt16Big(PacketID);

    // begin props
    Props := TMemoryStream.Create;
    with Props do begin
      if ResponseTopic <> '' then begin
        WriteByte(8);
        WriteMQTTString(ResponseTopic);       // response topic   (Ch. 3.3.2.3.5)
      end;
      if Length(CorrelData) > 0 then begin
        WriteByte(9);
        WriteMQTTBin(CorrelData);             // correlation data (Ch. 3.3.2.3.6)
      end;
    end;
    Props.Seek(0, soBeginning);
    WriteVarInt(Props.Size);
    CopyFrom(Props, Props.Size);
    Props.Free;
    // end props

    // begin payload
    WriteBuffer(Message[1], Length(Message)); //                  (Ch. 3.3.3)
    // end payload
  end;

  // write an MQTT packet with fixed header and remaining data
  WriteMQTTPacket(mqptPublish, Flags, Remaining);
  Remaining.Free;
end;

function TMQTTStream.ReadVarInt: UInt32;
var
  Multiplier: UInt32;
  EncodedByte: Byte;
  Count: Byte;
begin
  // Ch. 1.5.5
  Multiplier := 1;
  Result := 0;
  Count := 0;
  repeat
    if Count > 3 then
       raise EMQTTMalformedInteger.Create('malformed encoded integer');
    EncodedByte := ReadByte;
    Result += (EncodedByte and $7f) * Multiplier;
    Multiplier *= 128;
    Inc(Count);
  until (EncodedByte and $80) = 0;
end;

function TMQTTStream.ReadInt16Big: UInt16;
begin
  // Ch. 1.5.2
  Result := ReadByte shl 8;
  Result += ReadByte;
end;

function TMQTTStream.ReadInt32Big: UInt32;
begin
  // Ch. 1.5.3
  Result := ReadByte shl 24;
  Result += ReadByte shl 16;
  Result += ReadByte shl 8;
  Result += ReadByte;
end;

function TMQTTStream.ReadMQTTString: UTF8String;
var
  L: UInt16;
begin
  // Ch. 1.5.4
  L := ReadInt16Big;
  SetLength(Result, L);
  ReadBuffer(Result[1], L); // traditionally strings have 1-based indices in Pascal
end;

function TMQTTStream.ReadMQTTBin: TBytes;
var
  L: UInt16;
begin
  // Ch. 1.5.6
  Result := [];
  L := ReadInt16Big;
  SetLength(Result, L);
  ReadBuffer(Result[0], L);
end;

function TMQTTStream.ReadMQTTPacket: TMQTTParsedPacket;
var
  Fixed: Byte;
  Typ: TMQTTPacketType;
  Flags: Byte;
  RemLen: UInt32;
  Remaining: TMemoryStream;
begin
  // fixed header
  Fixed := ReadByte;
  Typ := TMQTTPacketType(Fixed shr 4);
  Flags := Fixed and $0f;

  // variable header and all remaining bytes
  RemLen := ReadVarInt;
  Remaining := TMemoryStream.Create;
  if RemLen > 0 then
    Remaining.CopyFrom(Self, RemLen);
  case Typ of
    mqptConnAck:  Result := TMQTTConnAck.Create(Typ, Flags, Remaining);
    mqptPingResp: Result := TMQTTPingResp.Create(Typ, Flags, Remaining);
    mqptSubAck:   Result := TMQTTSubAck.Create(Typ, Flags, Remaining);
    mqptPublish:  Result := TMQTTPublish.Create(Typ, Flags, Remaining);
  else
    Result := TMQTTParsedPacket.Create(Typ, Flags, Remaining);
  end;
end;

end.

