using Rug.Osc;

namespace Lib.io.osc;

[Guid("4e99da86-482f-4037-8664-b2371526d632")]
internal sealed class OscOutput : Instance<OscOutput>, IStatusProvider
{
    [Output(Guid = "a6679d6c-fc34-4588-ab20-5079ad8f8a03")]
    public readonly Slot<Command> Result = new();

    public OscOutput()
    {
        Result.UpdateAction += Update;
    }
        
    private void Update(EvaluationContext context)
    {
        // We can't initialize this in constructor because parent is not set yet
        _valuesInput ??= GetSymbolInput(Values);
        _stringsInput ??= GetSymbolInput(Strings);
            
        var oscAddress = Address.GetValue(context);
        var somethingHasChanged = false;
        var port = Port.GetValue(context);
        var ipAddressString = IpAddress.GetValue(context).Trim();
        var reconnect = Reconnect.GetValue(context);
        if (reconnect)
        {
            Reconnect.SetTypedInputValue(false);
        }

        var ipAddressChanged = ipAddressString != _lastIpAddressString;
        if (ipAddressChanged)
        {
            _lastIpAddressString = ipAddressString;
            if (!TryGetValidAddress(ipAddressString, out var error, out _newIpAddress))
            {
                _lastErrorMessage = error;
                return;
            }
        }

        if (port is <= 0 or > 65535)
        {
            _lastErrorMessage = "Port must be found in 1-65535 range";
            return;
        }

        if (_connected)
        {
            var targetChanged = ipAddressChanged || port != _port;
            if (targetChanged || reconnect)
            {
                somethingHasChanged = true;
                _sender.Close();
                _connected = TryConnectOsc(_newIpAddress, port);
            }
        }
        else if(_newIpAddress != null)
        {
            _connected = TryConnectOsc(_newIpAddress, port);
        }

        if (OscAddress.IsValidAddressPattern(oscAddress) == false)
        {
            _lastErrorMessage = $"The OSC location '{oscAddress}' is invalid";
            return;
        }


        {
            var connectedValues = Values.GetCollectedTypedInputs();
            var connectedValueCount = connectedValues.Count;
            var isValueDefault = IsInputDefault(_valuesInput);
                
            var totalValueCount = connectedValueCount > 0 
                                      ? connectedValueCount 
                                      : isValueDefault ? 0 : 1;

            // Rebuild list
            if (totalValueCount != _values.Count)
            {
                _values.Clear();
                if (connectedValueCount == 0)
                {
                    if(!isValueDefault)
                        _values.Add(Values.GetValue(context));
                }
                else
                {
                    foreach (var value in connectedValues)
                    {
                        _values.Add(value.GetValue(context));
                    }
                }
                somethingHasChanged= true;
            }
            // Update existing values
            else
            {
                if (connectedValueCount == 0)
                {
                    if (!isValueDefault)
                    {
                        var newValue = Values.GetValue(context);
                        if (Math.Abs(_values[0] - newValue) > 0.0001f)
                        {
                            somethingHasChanged = true;
                            _values[0] = newValue;
                        }
                    }
                }
                else
                {
                    for (var index = 0; index < connectedValues.Count; index++)
                    {
                        var newValue = connectedValues[index].GetValue(context);
                        var lastValue = _values[index];
                        if (Math.Abs(newValue - lastValue) > 0.0001f)
                        {
                            _values[index] = newValue;
                            somethingHasChanged = true;
                        }
                    }
                }
            }
        }

        // Rebuild string list
        {
            var connectedStrings = Strings.GetCollectedTypedInputs();
            var connectedStringCount = connectedStrings.Count;
            var isStringDefault = IsInputDefault(_stringsInput);
            var totalStringCount = connectedStringCount > 0 
                                       ? connectedStringCount 
                                       : isStringDefault ? 0 : 1;
                
            if (totalStringCount != _strings.Count)
            {
                _strings.Clear();
                if (connectedStringCount == 0)
                {
                    if(!isStringDefault)
                        _strings.Add(Strings.GetValue(context));
                }
                else
                {
                    foreach (var value in connectedStrings)
                    {
                        _strings.Add(value.GetValue(context));
                    }
                }
                somethingHasChanged= true;
            }
            // Update existing strings
            else
            {
                if (connectedStringCount == 0)
                {
                    if (!isStringDefault)
                    {
                        var newString = Strings.GetValue(context);
                        if (newString != _strings[0])
                        {
                            somethingHasChanged = true;
                            _strings[0] = newString;
                        }
                    }
                }
                else
                {
                    for (var index = 0; index < connectedStrings.Count; index++)
                    {
                        var newString = connectedStrings[index].GetValue(context);
                        var lastString = _strings[index];
                        if (newString != lastString)
                        {
                            _strings[index] = newString;
                            somethingHasChanged = true;
                        }
                    }
                }
            }
        }

        var shouldSend = SendTrigger.GetValue(context) && (somethingHasChanged || !OnlySendChanges.GetValue(context));
        if (shouldSend)
        {
            try
            {
                var parameters = new object[_strings.Count + _values.Count];
                for (var i = 0; i < _values.Count; i++)
                {
                    parameters[i] = _values[i];
                }
                for(var i=0; i< _strings.Count; i++)
                {
                    parameters[i + _values.Count] = _strings[i];
                }

                var message = new OscMessage(oscAddress, parameters);
                if (message.Error != OscPacketError.None)
                {
                    _lastErrorMessage = $"Failed to send OSC message: {message.ErrorMessage}";
                    return;
                }

                _sender.Send(message);
                _lastErrorMessage = null;
            }
            catch (Exception e)
            {
                _lastErrorMessage = $"Failed to send OSC message: {e.Message}";
            }
        }
        _lastErrorMessage = null;
    }

    private readonly List<float> _values = new();
    private readonly List<string> _strings = new();

    protected override void Dispose(bool isDisposing)
    {
        if (isDisposing && _connected) 
            _sender.Dispose();
    }

    private static bool TryGetValidAddress(string ipAddressString, out string error, out IPAddress ipAddress)
    {
        if (IPAddress.TryParse(ipAddressString, out ipAddress))
        {
            error = null;
            return true;
        }

        error = $"Failed to parse ip: {ipAddressString}";
        return false;
    }

    private bool TryConnectOsc(IPAddress ipAddress, int port)
    {
        if (ipAddress == null)
            return false;
            
        try
        {
            // The '0' picks a random available outbound (send) port
            // it defaults to "port" otherwise, which break server if it's
            // running on the same IP.
            _sender = new OscSender(ipAddress, 0, port);
            _sender.Connect();
            if (_sender.State == OscSocketState.Connected)
            {
                _port = port;
                return true;
            }
        }
        catch (Exception)
        {
            _lastErrorMessage = $"Failed to connect to {ipAddress}:{port}";
        }

        return false;
    }

    private static Symbol.Child.Input GetSymbolInput(ISlot inputSlot)
    {
        var op = inputSlot?.Parent;
        var composition = op?.Parent;
        var symbolChild = composition?.Children[op.SymbolChildId];
        var symbolInput = symbolChild?.Inputs.FirstOrDefault(i => i.Id == inputSlot.Id);
        return symbolInput?.Input;
    }
        
    private static bool IsInputDefault(Symbol.Child.Input symbolInput)
    {
        return symbolInput != null && symbolInput.IsDefault;
    }
        
    private OscSender _sender;
    private string _lastIpAddressString;
    private bool _connected;
    private int _port;
        
    private  Symbol.Child.Input _valuesInput;
    private  Symbol.Child.Input _stringsInput;
    private IPAddress _newIpAddress = null;

        
    public IStatusProvider.StatusLevel GetStatusLevel()
    {
        return string.IsNullOrEmpty(_lastErrorMessage) ? IStatusProvider.StatusLevel.Success : IStatusProvider.StatusLevel.Warning;
    }

    string IStatusProvider.GetStatusMessage() => _lastErrorMessage;
    private string _lastErrorMessage;

    [Input(Guid = "3CCA3654-2428-4526-8ED6-D1FA088C0BF9")]
    public readonly InputSlot<bool> SendTrigger = new();

    [Input(Guid = "98f38caa-4f79-425c-ab46-22d7dbe62978")]
    public readonly InputSlot<string> IpAddress = new();

    [Input(Guid = "6c0e07ba-7ea6-4dab-af0b-61cf9cb74ad7")]
    public readonly InputSlot<int> Port = new();
        
    [Input(Guid = "9016e418-7761-4916-aafb-c95599f77f38")]
    public readonly InputSlot<string> Address = new();
        
    [Input(Guid = "FDB1D27B-9A9D-47AB-8DBF-7E1BAB5B4A24")]
    public readonly InputSlot<bool> Reconnect = new();

    [Input(Guid = "827c7ae2-c129-4d04-a715-328c0a86bf8a")]
    public readonly MultiInputSlot<float> Values = new();

    [Input(Guid = "d5e9e9be-093b-4d57-9070-9b2cf33aa45b")]
    public readonly MultiInputSlot<string> Strings = new();

    [Input(Guid = "13B11154-C8F0-453E-A64E-80D602319B73")]
    public readonly InputSlot<bool> OnlySendChanges = new();
}