#include <vector>
#include <CoreAudio/CoreAudio.h>
#import "WindowDelegate.h"
#include "AudioDevice.h"
#include "ProxyAudioDevice.h"

int onDevicesChanged(AudioObjectID inObjectID,
                     UInt32 inNumberAddresses,
                     const AudioObjectPropertyAddress *inAddresses,
                     void *inClientData);

static NSString *const kDeviceNameCacheKey = @"deviceNameCacheByUID";

@implementation WindowDelegate {
    std::vector<AudioDeviceID> currentDeviceList;
    int initializationAttemptInterval;
    NSTimer *refreshTimer;
    NSString *lastDeviceListSignature;
    bool offlineFallbackUIBuilt;
}

- (void)awakeFromNib {
    self.deviceNameTextField.stringValue = NSLocalizedString(@"< Loading... >", nil);
    self.deviceNameTextField.enabled = NO;
    self.outputDeviceComboBox.enabled = NO;
    self.bufferSizeComboBox.enabled = NO;
    self.proxiedDeviceIsActiveRadioButton.enabled = NO;
    self.userIsActiveRadioButton.enabled = NO;
    self.alwaysRadioButton.enabled = NO;
    self.hideWhenUnavailableCheckbox.enabled = NO;
    initializationAttemptInterval = 3;
    offlineFallbackUIBuilt = false;
    [self keepTryingToInitializeUntilSuccess];
}

- (void)keepTryingToInitializeUntilSuccess {
    // For some reason, sometimes when the app launches right after the system boots we'll get bunk data
    // for all of the connected audio devices. If that happens then we'll try to initialize again after
    // a few seconds. We're initially waiting three seconds because that seems to work. Using less time
    // can actually cause the audio server to crash, so we want to be careful not to query it too often!
    bool success = [self initialize];
    
    if (!success) {
        NSLog(@"NB: failed to initialize, will try again in a sec...");
        [NSTimer scheduledTimerWithTimeInterval:initializationAttemptInterval target:self selector:@selector(keepTryingToInitializeUntilSuccess) userInfo:nil repeats:NO];
        // Increase the length of time between attempting to initialize by two seconds each time, just to be safe:
        initializationAttemptInterval += 2;
    }
}

- (bool)initialize {
    if (![self setCurrentProcessAsConfigurator]) {
        return false;
    }
    
    self.deviceNameTextField.stringValue = [self currentDeviceName];
    
    if (![self proxyAudioDeviceAvailable]) {
        // It's expected that we won't find the Proxy Audio Device if it's not installed, so this
        // technically isn't a failure case where we'd want to try initializing the app again.
        return true;
    }
    
    [self setupOfflineFallbackUI];

    if (![self refreshOutputDevices]) {
        return false;
    }
    
    if (![self setupListenerForCurrentAudioDevices]) {
        return false;
    }

    [self startRefreshTimer];
    
    [self.bufferSizeComboBox selectItemWithObjectValue:[self currentOutputDeviceBufferFrameSize]];
    self.deviceNameTextField.enabled = YES;
    self.outputDeviceComboBox.enabled = YES;
    self.bufferSizeComboBox.enabled = YES;
    self.proxiedDeviceIsActiveRadioButton.enabled = YES;
    self.userIsActiveRadioButton.enabled = YES;
    self.alwaysRadioButton.enabled = YES;
    self.hideWhenUnavailableCheckbox.enabled = YES;
    self.hideWhenUnavailableCheckbox.state =
        [self currentHideWhenUnavailable] ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.offlineFallbackCheckbox) {
        self.offlineFallbackCheckbox.enabled = YES;
        self.offlineFallbackCheckbox.state =
            [self currentOfflineFallback] ? NSControlStateValueOn : NSControlStateValueOff;
    }

    ProxyAudioDevice::ActiveCondition condition = [self currentOutputDeviceActiveCondition];

    if (condition == ProxyAudioDevice::ActiveCondition::proxiedDeviceActive) {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOn;
        self.userIsActiveRadioButton.state = NSControlStateValueOff;
        self.alwaysRadioButton.state = NSControlStateValueOff;
    } else if (condition == ProxyAudioDevice::ActiveCondition::userActive) {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
        self.userIsActiveRadioButton.state = NSControlStateValueOn;
        self.alwaysRadioButton.state = NSControlStateValueOff;
    } else {
        self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
        self.userIsActiveRadioButton.state = NSControlStateValueOff;
        self.alwaysRadioButton.state = NSControlStateValueOn;
    }

    return true;
}

- (bool)setCurrentProcessAsConfigurator {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    
    if (proxyAudioBox == kAudioObjectUnknown) {
        NSLog(@"Error: unable to find proxy audio device");
        // It's expected that we won't find the Proxy Audio Device if it's not installed, so this
        // technically isn't a failure case where we'd want to try initializing the app again.
        return true;
    }
    
    if (!AudioDevice::setIdentifyValue(proxyAudioBox, getpid())) {
        NSLog(@"Error: unable to set current process as configurator");
        return false;
    }
    
    return true;
}

int onDevicesChanged(AudioObjectID inObjectID,
                     UInt32 inNumberAddresses,
                     const AudioObjectPropertyAddress *inAddresses,
                     void *inClientData) {
#pragma unused(inObjectID, inNumberAddresses, inAddresses)
    dispatch_async(dispatch_get_main_queue(), ^{
        WindowDelegate *delegate = (__bridge WindowDelegate *)inClientData;
        [delegate refreshOutputDevices];
    });

    return noErr;
}

- (bool)setupListenerForCurrentAudioDevices {
    AudioObjectPropertyAddress listenerPropertyAddress = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    OSStatus err =
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &listenerPropertyAddress, &onDevicesChanged, (__bridge_retained void *)self);

    if (err != noErr) {
        NSLog(@"Error: could not set up listener for audio devices changing");
        return false;
    }
    
    return true;
}

- (bool)proxyAudioDeviceAvailable {
    return AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID)) != kAudioObjectUnknown;
}

- (NSString *)currentDeviceName {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::deviceName));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
    
    return result ? result : NSLocalizedString(@"< Proxy Audio Device not found >", nil);
}

- (IBAction)deviceNameEntered:(id)sender {
#pragma unused(sender)
    NSString *newName = [self.deviceNameTextField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if (newName.length == 0) {
        self.deviceNameTextField.stringValue = [self currentDeviceName];
        return;
    }

    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(proxyAudioBox,
                               (__bridge_retained CFStringRef)[NSString stringWithFormat:@"deviceName=%@", newName]);
}

- (NSString *)readConfigValueForType:(ProxyAudioDevice::ConfigType)type {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)type));
    return (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
}

- (void)writeConfigString:(NSString *)keyValue {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(proxyAudioBox, (__bridge CFStringRef)keyValue);
}

- (NSString *)currentOutputDeviceUID {
    NSString *uid = [self readConfigValueForType:ProxyAudioDevice::ConfigType::outputDevice];
    return uid.length > 0 ? uid : nil;
}

- (NSString *)currentOutputDeviceDisplayName {
    NSString *name = [self readConfigValueForType:ProxyAudioDevice::ConfigType::outputDeviceDisplayName];
    if (name.length > 0) {
        return name;
    }

    NSString *uid = [self currentOutputDeviceUID];
    if (uid.length == 0) {
        return nil;
    }

    NSDictionary *cache = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kDeviceNameCacheKey];
    NSString *cached = cache[uid];
    return cached.length > 0 ? cached : uid;
}

- (void)cacheName:(NSString *)name forUID:(NSString *)uid {
    if (name.length == 0 || uid.length == 0) {
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *cache = [([defaults dictionaryForKey:kDeviceNameCacheKey] ?: @{}) mutableCopy];
    if ([cache[uid] isEqualToString:name]) {
        return;
    }

    cache[uid] = name;
    [defaults setObject:cache forKey:kDeviceNameCacheKey];
}

- (AudioDeviceID)currentOutputDevice {
    NSString *outputDeviceUID = [self currentOutputDeviceUID];
    if (outputDeviceUID.length == 0) {
        return kAudioObjectUnknown;
    }

    return AudioDevice::audioDeviceIDForDeviceUID((__bridge CFStringRef)outputDeviceUID);
}

- (void)startRefreshTimer {
    if (refreshTimer) {
        return;
    }

    refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                    target:self
                                                  selector:@selector(pollRefresh)
                                                  userInfo:nil
                                                   repeats:YES];
}

- (void)pollRefresh {
    if (self.outputDeviceComboBox.window.isVisible) {
        [self refreshOutputDevices];
    }
}

- (NSString *)currentDeviceListSignature {
    NSString *storedUID = [self currentOutputDeviceUID] ?: @"";
    NSMutableString *signature = [NSMutableString stringWithFormat:@"%@;", storedUID];
    std::vector<AudioDeviceID> devices = AudioDevice::devicesWithOutputCapabilitiesThatAreNotProxyAudioDevice();

    for (AudioDeviceID device : devices) {
        NSString *uid = (__bridge_transfer NSString *)AudioDevice::copyDeviceUID(device);
        [signature appendFormat:@"%@;", uid ?: @""];
    }

    return signature;
}

- (bool)refreshOutputDevices {
    NSString *signature = [self currentDeviceListSignature];
    if ([signature isEqualToString:lastDeviceListSignature] && self.outputDeviceComboBox.numberOfItems > 0) {
        return true;
    }
    lastDeviceListSignature = signature;

    bool success = false;
    [self.outputDeviceComboBox removeAllItems];
    currentDeviceList = AudioDevice::devicesWithOutputCapabilitiesThatAreNotProxyAudioDevice();
    NSString *storedUID = [self currentOutputDeviceUID];
    bool foundStoredDevice = false;
    
    for (unsigned int i = 0; i < currentDeviceList.size(); ++i) {
        NSString *deviceName = (__bridge_transfer NSString *)AudioDevice::copyObjectName(currentDeviceList[i]);
        NSString *uid = (__bridge_transfer NSString *)AudioDevice::copyDeviceUID(currentDeviceList[i]);
        
        if (!deviceName) {
            NSLog(@"Note: got null device name for audio device with device with ID: %d", currentDeviceList[i]);
            continue;
        }

        if (uid.length > 0) {
            [self cacheName:deviceName forUID:uid];
        }
        
        [self.outputDeviceComboBox addItemWithObjectValue:deviceName];
        
        if (storedUID.length > 0 && [uid isEqualToString:storedUID]) {
            [self.outputDeviceComboBox selectItemAtIndex:i];
            foundStoredDevice = true;
        }
        
        success = true;
    }

    if (!foundStoredDevice && storedUID.length > 0) {
        NSString *displayName = [self currentOutputDeviceDisplayName] ?: storedUID;
        NSString *offlineName = [NSString stringWithFormat:NSLocalizedString(@"%@（离线）", nil), displayName];
        [self.outputDeviceComboBox addItemWithObjectValue:offlineName];
        currentDeviceList.push_back(kAudioObjectUnknown);
        [self.outputDeviceComboBox selectItemAtIndex:(NSInteger)currentDeviceList.size() - 1];
        success = true;
    }
    
    if (!success) {
        NSLog(@"Error: failed to get any information about current output devices!");
    }
    
    return success;
}

- (IBAction)outputDeviceSelected:(id)sender {
#pragma unused(sender)
    unsigned long index = (unsigned long)self.outputDeviceComboBox.indexOfSelectedItem;
    
    if (index < 0 || index >= currentDeviceList.size()) {
        NSLog(@"Error: got invalid selection index when trying to set output device");
        return;
    }

    if (currentDeviceList[index] == kAudioObjectUnknown) {
        return;
    }

    NSString *uid = (__bridge_transfer NSString *)AudioDevice::copyDeviceUID(currentDeviceList[index]);
    
    if (!uid) {
        NSLog(@"Error: got invalid UID when trying to set output device");
        return;
    }

    [self writeConfigString:[NSString stringWithFormat:@"outputDevice=%@", uid]];
    lastDeviceListSignature = nil;
    [self refreshOutputDevices];
}

- (NSString *)currentOutputDeviceBufferFrameSize {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::outputDeviceBufferFrameSize));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
    
    return result ? result : @"";
}

- (IBAction)outputDeviceBufferFrameSizeSelected:(id)sender {
#pragma unused(sender)
    NSString *newBufferFrameSizeString = self.bufferSizeComboBox.objectValueOfSelectedItem;

    if (!newBufferFrameSizeString) {
        NSLog(@"Error: got invalid buffer frame size value");
        return;
    }

    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(
        proxyAudioBox,
        (__bridge_retained CFStringRef)
            [NSString stringWithFormat:@"outputDeviceBufferFrameSize=%@", newBufferFrameSizeString]);
}

- (ProxyAudioDevice::ActiveCondition)currentOutputDeviceActiveCondition {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::deviceActiveCondition));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);

    return (ProxyAudioDevice::ActiveCondition)[result intValue];
}

- (void)setCurrentOutputDeviceActiveCondition:(ProxyAudioDevice::ActiveCondition)condition {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(
        proxyAudioBox,
        (__bridge_retained CFStringRef)
            [NSString stringWithFormat:@"outputDeviceActiveCondition=%d", condition]);
}

- (IBAction)proxiedDeviceIsActiveConditionSelected:(id)sender {
    #pragma unused(sender)
    self.alwaysRadioButton.state = NSControlStateValueOff;
    self.userIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::proxiedDeviceActive];
}

- (IBAction)userIsActiveConditionSelected:(id)sender {
    #pragma unused(sender)
    self.alwaysRadioButton.state = NSControlStateValueOff;
    self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::userActive];
}

- (IBAction)alwaysConditionSelected:(id)sender {
    #pragma unused(sender)
    self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
    self.userIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::always];
}

// The driver reports this preference as "1" or "0" (see copyConfigurationValue
// in ProxyAudioDevice.cpp). Anything non-"1" is treated as false.
- (bool)currentHideWhenUnavailable {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::deviceHideWhenUnavailable));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);

    return [result intValue] != 0;
}

- (void)setCurrentHideWhenUnavailable:(bool)hide {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setObjectName(
        proxyAudioBox,
        (__bridge_retained CFStringRef)
            [NSString stringWithFormat:@"outputDeviceHideWhenUnavailable=%d", hide ? 1 : 0]);
}

- (IBAction)hideWhenUnavailableToggled:(id)sender {
    #pragma unused(sender)
    [self setCurrentHideWhenUnavailable:(self.hideWhenUnavailableCheckbox.state == NSControlStateValueOn)];
}

- (bool)currentOfflineFallback {
    NSString *result = [self readConfigValueForType:ProxyAudioDevice::ConfigType::outputDeviceOfflineFallback];
    return [result intValue] != 0;
}

- (void)setCurrentOfflineFallback:(bool)fallBackToSpeakers {
    [self writeConfigString:[NSString stringWithFormat:@"outputDeviceOfflineFallback=%d", fallBackToSpeakers ? 1 : 0]];
}

- (IBAction)offlineFallbackToggled:(id)sender {
#pragma unused(sender)
    [self setCurrentOfflineFallback:(self.offlineFallbackCheckbox.state == NSControlStateValueOn)];
}

- (void)setupOfflineFallbackUI {
    if (offlineFallbackUIBuilt) {
        return;
    }

    NSWindow *window = self.deviceNameTextField.window;
    NSView *contentView = window.contentView;
    if (!window || !contentView) {
        return;
    }

    const CGFloat extraHeight = 28.0;
    NSRect frame = window.frame;
    frame.size.height += extraHeight;
    [window setFrame:frame display:YES];

    NSSize maxSize = window.contentMaxSize;
    NSSize minSize = window.contentMinSize;
    maxSize.height += extraHeight;
    minSize.height += extraHeight;
    window.contentMaxSize = maxSize;
    window.contentMinSize = minSize;

    NSButton *checkbox = [[NSButton alloc] initWithFrame:NSZeroRect];
    [checkbox setButtonType:NSButtonTypeSwitch];
    checkbox.title = NSLocalizedString(@"LG C3 离线时回退到 Mac mini 扬声器（默认静音）", nil);
    checkbox.target = self;
    checkbox.action = @selector(offlineFallbackToggled:);
    checkbox.frame = NSMakeRect(157.0, 20.0, 336.0, 18.0);
    checkbox.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    checkbox.enabled = NO;
    [contentView addSubview:checkbox];
    self.offlineFallbackCheckbox = checkbox;

    offlineFallbackUIBuilt = true;
}

@end
