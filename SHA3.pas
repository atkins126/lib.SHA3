{-------------------------------------------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

-------------------------------------------------------------------------------}
{===============================================================================

  SHA3/Keccak hash calculation

  ©František Milt 2015-06-04

  Version 1.1

  Following hash variants are supported in current implementation:
    Keccak224
    Keccak256
    Keccak384
    Keccak512
    Keccak[] (in this library marked as Keccak_b)
    SHA3-224
    SHA3-256
    SHA3-384
    SHA3-512
    SHAKE128
    SHAKE256

===============================================================================}
unit SHA3;

interface

{$DEFINE LargeBuffer}
{.$DEFINE UseStringStream}

uses
  Classes;

type
{$IFDEF x64}
  PtrUInt = UInt64;
{$ELSE}
  PtrUInt = LongWord;
{$ENDIF}

  TSize = PtrUInt;


  TKeccakHashSize = (Keccak224,Keccak256,Keccak384,Keccak512,Keccak_b,
                     SHA3_224,SHA3_256,SHA3_384,SHA3_512,SHAKE128,SHAKE256);
                     
  TSHA3HashSize = TKeccakHashSize;

  TKeccakSponge = Array[0..4,0..4] of Int64;  // First index is Y, second X

  TKeccakState = record
    HashSize:   TKeccakHashSize;
    HashBits:   LongWord;
    BlockSize:  LongWord;
    Sponge:     TKeccakSponge;
  end;

  TSHA3State = TKeccakState;

  TKeccakHash = record
    HashSize: TKeccakHashSize;
    HashBits: LongWord;
    HashData: Array of Byte;
  end;

  TSHA3Hash = TKeccakHash;

Function GetBlockSize(HashSize: TSHA3HashSize): LongWord;

Function InitialSHA3State(HashSize: TSHA3HashSize; HashBits: LongWord = 0): TSHA3State;

Function SHA3ToStr(Hash: TSHA3Hash): String;
Function StrToSHA3(HashSize: TSHA3HashSize; Str: String): TSHA3Hash;
Function TryStrToSHA3(HashSize: TSHA3HashSize;const Str: String; out Hash: TSHA3Hash): Boolean;
Function StrToSHA3Def(HashSize: TSHA3HashSize;const Str: String; Default: TSHA3Hash): TSHA3Hash;
Function SameSHA3(A,B: TSHA3Hash): Boolean;

procedure BufferSHA3(var State: TSHA3State; const Buffer; Size: TSize); overload;
Function LastBufferSHA3(State: TSHA3State; const Buffer; Size: TSize): TSHA3Hash;

Function BufferSHA3(HashSize: TSHA3HashSize; const Buffer; Size: TSize; HashBits: LongWord = 0): TSHA3Hash; overload;

Function AnsiStringSHA3(HashSize: TSHA3HashSize; const Str: AnsiString; HashBits: LongWord = 0): TSHA3Hash;
Function WideStringSHA3(HashSize: TSHA3HashSize; const Str: WideString; HashBits: LongWord = 0): TSHA3Hash;
Function StringSHA3(HashSize: TSHA3HashSize; const Str: String; HashBits: LongWord = 0): TSHA3Hash;

Function StreamSHA3(HashSize: TSHA3HashSize; Stream: TStream; Count: Int64 = -1; HashBits: LongWord = 0): TSHA3Hash;
Function FileSHA3(HashSize: TSHA3HashSize; const FileName: String; HashBits: LongWord = 0): TSHA3Hash;

//------------------------------------------------------------------------------

type
  TSHA3Context = type Pointer;

Function SHA3_Init(HashSize: TSHA3HashSize; HashBits: LongWord = 0): TSHA3Context;
procedure SHA3_Update(Context: TSHA3Context; const Buffer; Size: TSize);
Function SHA3_Final(var Context: TSHA3Context; const Buffer; Size: TSize): TSHA3Hash; overload;
Function SHA3_Final(var Context: TSHA3Context): TSHA3Hash; overload;
Function SHA3_Hash(HashSize: TSHA3HashSize; const Buffer; Size: TSize; HashBits: LongWord = 0): TSHA3Hash;


implementation

uses
  SysUtils, Math;

const
  RoundConsts: Array[0..23] of Int64 = (
    $0000000000000001, $0000000000008082, $800000000000808A, $8000000080008000,
    $000000000000808B, $0000000080000001, $8000000080008081, $8000000000008009,
    $000000000000008A, $0000000000000088, $0000000080008009, $000000008000000A,
    $000000008000808B, $800000000000008B, $8000000000008089, $8000000000008003,
    $8000000000008002, $8000000000000080, $000000000000800A, $800000008000000A,
    $8000000080008081, $8000000000008080, $0000000080000001, $8000000080008008);

  RotateCoefs: Array[0..4,0..4] of Byte = ( // first index is X, second Y
    {X = 0} ( 0,36, 3,41,18),
    {X = 1} ( 1,44,10,45, 2),
    {X = 2} (62, 6,43,15,61),
    {X = 3} (28,55,25,21,56),
    {X = 4} (27,20,39, 8,14));

type
  TSHA3Context_Internal = record
    HashState:      TSHA3State;
    TransferSize:   LongWord;
    TransferBuffer: Array[0..199] of Byte;
  end;
  PSHA3Context_Internal = ^TSHA3Context_Internal;

//==============================================================================    

{$IFDEF FPC}{$ASMMODE intel}{$ENDIF}

Function ROL(Value: Int64; Shift: Byte): Int64;{$IFNDEF PurePascal}assembler;{$ENDIF}
{$IFDEF PurePascal}
begin
Shift := Shift and $3F;
Result := (Value shl Shift) or (Value shr (64 - Shift));
end;
{$ELSE}
asm
{$IFDEF x64}
    MOV   RAX,  RCX
    MOV   CL,   DL
    ROL   RAX,  CL
{$ELSE}
    MOV   ECX,  EAX
    AND   ECX,  $3F
    CMP   ECX,  32

    JAE   @Above31

  @Below32:
    MOV   EAX,  dword ptr [Value]
    MOV   EDX,  dword ptr [Value + 4]
    CMP   ECX,  0
    JE    @FuncEnd

    MOV   dword ptr [Value],  EDX
    JMP   @Rotate

  @Above31:
    MOV   EDX,  dword ptr [Value]
    MOV   EAX,  dword ptr [Value + 4]
    JE    @FuncEnd

    AND   ECX,  $1F

  @Rotate:
    SHLD  EDX,  EAX, CL
    SHL   EAX,  CL
    PUSH  EAX
    MOV   EAX,  dword ptr [Value]
    XOR   CL,   31
    INC   CL
    SHR   EAX,  CL
    POP   ECX
    OR    EAX,  ECX

  @FuncEnd:
{$ENDIF}
end;
{$ENDIF}

//==============================================================================

procedure Permute(var State: TKeccakState);
var
  i,x,y:  Integer;
  B:      TKeccakSponge;
  C,D:    Array[0..4] of Int64;

  Function WrapIndex(Idx: Integer): Integer;
  begin
    while Idx > 4 do Dec(Idx,5);
    while Idx < 0 do Inc(Idx,5);
    Result := Idx;
  end;

begin
For i := 0 to 23 do // 24 rounds (12 + 2L; where L = log2(64) = 6; 64 is length of sponge word in bits)
  begin
    For x := 0 to 4 do
      C[x] := State.Sponge[0,x] xor State.Sponge[1,x] xor State.Sponge[2,x] xor State.Sponge[3,x] xor State.Sponge[4,x];

    For x := 0 to 4 do
      D[x] := C[WrapIndex(x - 1)] xor ROL(C[WrapIndex(x + 1)],1);
    For x := 0 to 4 do
      For y := 0 to 4 do
        State.Sponge[y,x] := State.Sponge[y,x] xor D[x];

    For x := 0 to 4 do
      For y := 0 to 4 do
        B[WrapIndex(2 *x + 3 * y),y] := ROL(State.Sponge[y,x],RotateCoefs[x,y]);

    For x := 0 to 4 do
      For y := 0 to 4 do
        State.Sponge[y,x] := B[y,x] xor ((not B[y,WrapIndex(x + 1)]) and B[y,WrapIndex(x + 2)]);

    State.Sponge[0,0] := State.Sponge[0,0] xor RoundConsts[i];
  end;
end;

//------------------------------------------------------------------------------

procedure BlockHash(var State: TKeccakState; const Block);
var
  i:    Integer;
  Buff: PInt64;
begin
Buff := @Block;
For i := 0 to Pred(State.BlockSize shr 3) do
  begin
    State.Sponge[i div 5,i mod 5] := State.Sponge[i div 5,i mod 5] xor Buff^;
    Inc(Buff);
  end;
Permute(State);
end;

//------------------------------------------------------------------------------

procedure Squeeze(var State: TKeccakState; var Buffer);
var
  BytesToSqueeze: LongWord;
begin
BytesToSqueeze := State.HashBits shr 3;
If BytesToSqueeze > State.BlockSize then
  while BytesToSqueeze > 0 do
    begin
      {$IFDEF x64}
      Move(State.Sponge,{%H-}Pointer({%H-}PtrUInt(@Buffer) + (State.HashBits shr 3) - BytesToSqueeze)^,Min(BytesToSqueeze,State.BlockSize));
      {$ELSE}
      Move(State.Sponge,{%H-}Pointer({%H-}PtrUInt(@Buffer) + Int64(State.HashBits shr 3) - BytesToSqueeze)^,Min(BytesToSqueeze,State.BlockSize));
      {$ENDIF}
      Permute(State);
      Dec(BytesToSqueeze,Min(BytesToSqueeze,State.BlockSize));
    end
else Move(State.Sponge,Buffer,BytesToSqueeze);
end;

//==============================================================================

procedure PrepareHash(State: TSHA3State; out Hash: TSHA3Hash);
begin
Hash.HashSize := State.HashSize;
Hash.HashBits := State.HashBits;
SetLength(Hash.HashData,Hash.HashBits shr 3);
end;

//==============================================================================

Function GetBlockSize(HashSize: TKeccakHashSize): LongWord;
begin
case HashSize of
  Keccak224, SHA3_224:  Result := (1600 - (2 * 224)) shr 3;
  Keccak256, SHA3_256:  Result := (1600 - (2 * 256)) shr 3;
  Keccak384, SHA3_384:  Result := (1600 - (2 * 384)) shr 3;
  Keccak512, SHA3_512:  Result := (1600 - (2 * 512)) shr 3;
  Keccak_b:             Result := (1600 - 576) shr 3;
  SHAKE128:             Result := (1600 - (2 * 128)) shr 3;
  SHAKE256:             Result := (1600 - (2 * 256)) shr 3;
else
  raise Exception.CreateFmt('GetBlockSize: Unknown hash size (%d).',[Integer(HashSize)]);
end;
end;

//------------------------------------------------------------------------------

Function InitialSHA3State(HashSize: TSHA3HashSize; HashBits: LongWord = 0): TSHA3State;
begin
Result.HashSize := HashSize;
case HashSize of
  Keccak224, SHA3_224:  Result.HashBits := 224;
  Keccak256, SHA3_256:  Result.HashBits := 256;
  Keccak384, SHA3_384:  Result.HashBits := 384;
  Keccak512, SHA3_512:  Result.HashBits := 512;
  Keccak_b,
  SHAKE128,
  SHAKE256: begin
              If (HashBits and $7) <> 0 then
                raise Exception.Create('InitialSHA3State: HashBits must be divisible by 8.')
              else
                Result.HashBits := HashBits;
            end;
else
  raise Exception.CreateFmt('InitialSHA3State: Unknown hash size (%d).',[Integer(HashSize)]);
end;
Result.BlockSize := GetBlockSize(HashSize);
FillChar(Result.Sponge,SizeOf(Result.Sponge),0);
end;

//==============================================================================

Function SHA3ToStr(Hash: TSHA3Hash): String;
var
  i:  Integer;
begin
SetLength(Result,Length(Hash.HashData) * 2);
For i := Low(Hash.HashData) to High(Hash.HashData) do
  begin
    Result[(i * 2) + 1] := IntToHex(Hash.HashData[i],2)[1];
    Result[(i * 2) + 2] := IntToHex(Hash.HashData[i],2)[2];
  end;
end;

//------------------------------------------------------------------------------

Function StrToSHA3(HashSize: TSHA3HashSize; Str: String): TSHA3Hash;
var
  HashCharacters: Integer;
  i:              Integer;
begin
Result.HashSize := HashSize;
case HashSize of
  Keccak224, SHA3_224:  Result.HashBits := 224;
  Keccak256, SHA3_256:  Result.HashBits := 256;
  Keccak384, SHA3_384:  Result.HashBits := 384;
  Keccak512, SHA3_512:  Result.HashBits := 512;
  Keccak_b,
  SHAKE128,
  SHAKE256:  Result.HashBits := (Length(Str) shr 1) shl 3;
else
  raise Exception.CreateFmt('StrToSHA3: Unknown source hash size (%d).',[Integer(HashSize)]);
end;
HashCharacters := Result.HashBits shr 2;
If Length(Str) < HashCharacters then
  Str := StringOfChar('0',HashCharacters - Length(Str)) + Str
else
  If Length(Str) > HashCharacters then
    Str := Copy(Str,Length(Str) - HashCharacters + 1,HashCharacters);
SetLength(Result.HashData,Length(Str) shr 1);    
For i := Low(Result.HashData) to High(Result.HashData) do
  Result.HashData[i] := StrToInt('$' + Copy(Str,(i * 2) + 1,2));
end;

//------------------------------------------------------------------------------

Function TryStrToSHA3(HashSize: TSHA3HashSize; const Str: String; out Hash: TSHA3Hash): Boolean;
begin
try
  Hash := StrToSHA3(HashSize,Str);
  Result := True;
except
  Result := False;
end;
end;

//------------------------------------------------------------------------------

Function StrToSHA3Def(HashSize: TSHA3HashSize; const Str: String; Default: TSHA3Hash): TSHA3Hash;
begin
If not TryStrToSHA3(HashSize,Str,Result) then
  Result := Default;
end;

//------------------------------------------------------------------------------

Function SameSHA3(A,B: TSHA3Hash): Boolean;
var
  i:  Integer;
begin
Result := False;
If (A.HashBits = B.HashBits) and (A.HashSize = B.HashSize) and
  (Length(A.HashData) = Length(B.HashData)) then
  begin
    For i := Low(A.HashData) to High(A.HashData) do
      If A.HashData[i] <> B.HashData[i] then Exit;
    Result := True;
  end;
end;

//==============================================================================

procedure BufferSHA3(var State: TSHA3State; const Buffer; Size: TSize);
var
  i:    TSize;
  Buff: PByte;
begin
If Size > 0 then
  begin
    If (Size mod State.BlockSize) = 0 then
      begin
        Buff := @Buffer;
        For i := 0 to Pred(Size div State.BlockSize) do
          begin
            BlockHash(State,Buff^);
            Inc(Buff,State.BlockSize);
          end;
      end
    else raise Exception.CreateFmt('BufferSHA3: Buffer size is not divisible by %d.',[State.BlockSize]);
  end;
end;

//------------------------------------------------------------------------------

Function LastBufferSHA3(State: TSHA3State; const Buffer; Size: TSize): TSHA3Hash;
var
  FullBlocks:     TSize;
  LastBlockSize:  TSize;
  HelpBlocks:     TSize;
  HelpBlocksBuff: Pointer;
begin
FullBlocks := Size div State.BlockSize;
If FullBlocks > 0 then BufferSHA3(State,Buffer,FullBlocks * State.BlockSize);
{$IFDEF x64}
LastBlockSize := Size - (FullBlocks * State.BlockSize);
{$ELSE}
LastBlockSize := Size - (Int64(FullBlocks) * State.BlockSize);
{$ENDIF}
HelpBlocks := Ceil((LastBlockSize + 1) / State.BlockSize);
HelpBlocksBuff := AllocMem(HelpBlocks * State.BlockSize);
try
  Move({%H-}Pointer({%H-}PtrUInt(@Buffer) + (FullBlocks * State.BlockSize))^,HelpBlocksBuff^,LastBlockSize);
  case State.HashSize of
    Keccak224..Keccak_b:  {%H-}PByte({%H-}PtrUInt(HelpBlocksBuff) + LastBlockSize)^ := $01;
     SHA3_224..SHA3_512:  {%H-}PByte({%H-}PtrUInt(HelpBlocksBuff) + LastBlockSize)^ := $06;
     SHAKE128..SHAKE256:  {%H-}PByte({%H-}PtrUInt(HelpBlocksBuff) + LastBlockSize)^ := $1F;
  else
    raise Exception.CreateFmt('LastBufferSHA3: Unknown hash size (%d)',[Integer(State.HashSize)]);
  end;
  {$IFDEF x64}
  {%H-}PByte({%H-}PtrUInt(HelpBlocksBuff) + (HelpBlocks * State.BlockSize) - 1)^ := {%H-}PByte({%H-}PtrUInt(HelpBlocksBuff) + (HelpBlocks * State.BlockSize) - 1)^ xor $80;
  {$ELSE}
  {%H-}PByte({%H-}PtrUInt(HelpBlocksBuff) + (Int64(HelpBlocks) * State.BlockSize) - 1)^ := {%H-}PByte({%H-}PtrUInt(HelpBlocksBuff) + (Int64(HelpBlocks) * State.BlockSize) - 1)^ xor $80;
  {$ENDIF}
  BufferSHA3(State,HelpBlocksBuff^,HelpBlocks * State.BlockSize);
finally
  FreeMem(HelpBlocksBuff,HelpBlocks * State.BlockSize);
end;
PrepareHash(State,Result);
If Length(Result.HashData) > 0 then
  Squeeze(State,Addr(Result.HashData[0])^);
end;

//==============================================================================

Function BufferSHA3(HashSize: TSHA3HashSize; const Buffer; Size: TSize; HashBits: LongWord = 0): TSHA3Hash;
begin
Result := LastBufferSHA3(InitialSHA3State(HashSize,HashBits),Buffer,Size);
end;

//==============================================================================

Function AnsiStringSHA3(HashSize: TSHA3HashSize; const Str: AnsiString; HashBits: LongWord = 0): TSHA3Hash;
{$IFDEF UseStringStream}
var
  StringStream: TStringStream;
begin
StringStream := TStringStream.Create(Str);
try
  Result := StreamSHA3(HashSize,StringStream,-1,HashBits);
finally
  StringStream.Free;
end;
end;
{$ELSE}
begin
Result := BufferSHA3(HashSize,PAnsiChar(Str)^,Length(Str) * SizeOf(AnsiChar),HashBits);
end;
{$ENDIF}

//------------------------------------------------------------------------------

Function WideStringSHA3(HashSize: TSHA3HashSize; const Str: WideString; HashBits: LongWord = 0): TSHA3Hash;
{$IFDEF UseStringStream}
var
  StringStream: TStringStream;
begin
StringStream := TStringStream.Create(Str);
try
  Result := StreamSHA3(HashSize,StringStream,-1,HashBits);
finally
  StringStream.Free;
end;
end;
{$ELSE}
begin
Result := BufferSHA3(HashSize,PWideChar(Str)^,Length(Str) * SizeOf(WideChar),HashBits);
end;
{$ENDIF}

//------------------------------------------------------------------------------

Function StringSHA3(HashSize: TSHA3HashSize; const Str: String; HashBits: LongWord = 0): TSHA3Hash;
{$IFDEF UseStringStream}
var
  StringStream: TStringStream;
begin
StringStream := TStringStream.Create(Str);
try
  Result := StreamSHA3(HashSize,StringStream,-1,HashBits);
finally
  StringStream.Free;
end;
end;
{$ELSE}
begin
Result := BufferSHA3(HashSize,PChar(Str)^,Length(Str) * SizeOf(Char),HashBits);
end;
{$ENDIF}

//==============================================================================

Function StreamSHA3(HashSize: TSHA3HashSize; Stream: TStream; Count: Int64 = -1; HashBits: LongWord = 0): TSHA3Hash;
var
  Buffer:     Pointer;
  BytesRead:  LongWord;
  State:      TSHA3State;
  BufferSize: LongWord;
begin
If Assigned(Stream) then
  begin
    If Count = 0 then
      Count := Stream.Size - Stream.Position;
    If Count < 0 then
      begin
        Stream.Position := 0;
        Count := Stream.Size;
      end;
  {$IFDEF LargeBuffer}
    BufferSize := ($100000 div GetBlockSize(HashSize)) * GetBlockSize(HashSize);
  {$ELSE}
    BufferSize := ($1000 div GetBlockSize(HashSize)) * GetBlockSize(HashSize);
  {$ENDIF}
    GetMem(Buffer,BufferSize);
    try
      State := InitialSHA3State(HashSize,HashBits);
      repeat
        BytesRead := Stream.Read(Buffer^,Min(BufferSize,Count));
        If BytesRead < BufferSize then
          Result := LastBufferSHA3(State,Buffer^,BytesRead)
        else
          BufferSHA3(State,Buffer^,BytesRead);
        Dec(Count,BytesRead);
      until BytesRead < BufferSize;
    finally
      FreeMem(Buffer,BufferSize);
    end;
  end
else raise Exception.Create('StreamSHA3: Stream is not assigned.');
end;

//------------------------------------------------------------------------------

Function FileSHA3(HashSize: TSHA3HashSize; const FileName: String; HashBits: LongWord = 0): TSHA3Hash;
var
  FileStream: TFileStream;
begin
FileStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
try
  Result := StreamSHA3(HashSize,FileStream,-1,HashBits);
finally
  FileStream.Free;
end;
end;

//==============================================================================

Function SHA3_Init(HashSize: TSHA3HashSize; HashBits: LongWord = 0): TSHA3Context;
begin
Result := AllocMem(SizeOf(TSHA3Context_Internal));
with PSHA3Context_Internal(Result)^ do
  begin
    HashState := InitialSHA3State(HashSize,HashBits);
    TransferSize := 0;
  end;
end;

//------------------------------------------------------------------------------

procedure SHA3_Update(Context: TSHA3Context; const Buffer; Size: TSize);
var
  FullBlocks:     TSize;
  RemainingSize:  TSize;
begin
with PSHA3Context_Internal(Context)^ do
  begin
    If TransferSize > 0 then
      begin
        If Size >= (HashState.BlockSize - TransferSize) then
          begin
            Move(Buffer,TransferBuffer[TransferSize],HashState.BlockSize - TransferSize);
            BufferSHA3(HashState,TransferBuffer,HashState.BlockSize);
            RemainingSize := Size - (HashState.BlockSize - TransferSize);
            TransferSize := 0;
            SHA3_Update(Context,{%H-}Pointer({%H-}PtrUInt(@Buffer) + (Size - RemainingSize))^,RemainingSize);
          end
        else
          begin
            Move(Buffer,TransferBuffer[TransferSize],Size);
            Inc(TransferSize,Size);
          end;  
      end
    else
      begin
        FullBlocks := Size div HashState.BlockSize;
        BufferSHA3(HashState,Buffer,FullBlocks * HashState.BlockSize);
        If (FullBlocks * HashState.BlockSize) < Size then
          begin
            {$IFDEF x64}
            TransferSize := Size - (FullBlocks * HashState.BlockSize);
            {$ELSE}
            TransferSize := Size - (Int64(FullBlocks) * HashState.BlockSize);
            {$ENDIF}
            Move({%H-}Pointer({%H-}PtrUInt(@Buffer) + (Size - TransferSize))^,TransferBuffer,TransferSize);
          end;
      end;
  end;
end;

//------------------------------------------------------------------------------

Function SHA3_Final(var Context: TSHA3Context; const Buffer; Size: TSize): TSHA3Hash;
begin
SHA3_Update(Context,Buffer,Size);
Result := SHA3_Final(Context);
end;

//------------------------------------------------------------------------------

Function SHA3_Final(var Context: TSHA3Context): TSHA3Hash;
begin
with PSHA3Context_Internal(Context)^ do
  Result := LastBufferSHA3(HashState,TransferBuffer,TransferSize);
FreeMem(Context,SizeOf(TSHA3Context_Internal));
Context := nil;
end;

//------------------------------------------------------------------------------

Function SHA3_Hash(HashSize: TSHA3HashSize; const Buffer; Size: TSize; HashBits: LongWord = 0): TSHA3Hash;
begin
Result := LastBufferSHA3(InitialSHA3State(HashSize,HashBits),Buffer,Size);
end;

end.

