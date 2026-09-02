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
static NSString *const kHALDriverPath = @"/Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver";

@implementation WindowDelegate {
    std::vector<AudioDeviceID> currentDeviceList;
    int initializationAttemptInterval;
    NSTimer *refreshTimer;
    NSString *lastDeviceListSignature;
    bool nativeUIBuilt;
    bool audioListenerInstalled;
}

- (void)awakeFromNib {
    initializationAttemptInterval = 3;
    nativeUIBuilt = false;
    audioListenerInstalled = false;
    [self buildNativeUI];
    [self updateDriverStatus];
    [self setSettingsEnabled:NO];
    [self keepTryingToInitializeUntilSuccess];
}

- (void)keepTryingToInitializeUntilSuccess {
    bool success = [self initialize];
    if (!success) {
        [NSTimer scheduledTimerWithTimeInterval:initializationAttemptInterval
                                         target:self
                                       selector:@selector(keepTryingToInitializeUntilSuccess)
                                       userInfo:nil
                                        repeats:NO];
        initializationAttemptInterval += 2;
    }
}

- (bool)initialize {
    [self updateDriverStatus];

    if (![self proxyAudioDeviceAvailable]) {
        [self setSettingsEnabled:NO];
        return true;
    }

    if (![self setCurrentProcessAsConfigurator]) {
        return false;
    }

    self.deviceNameTextField.stringValue = [self currentDeviceName];

    if (![self refreshOutputDevices]) {
        return false;
    }

    if (!audioListenerInstalled && ![self setupListenerForCurrentAudioDevices]) {
        return false;
    }
    audioListenerInstalled = true;
    [self startRefreshTimer];

    NSString *bufferSize = [self currentOutputDeviceBufferFrameSize];
    if (bufferSize.length > 0) {
        [self.bufferSizePopUp selectItemWithTitle:bufferSize];
    }

    [self setSettingsEnabled:YES];
    [self updateActiveConditionControls];
    [self updateDriverStatus];
    return true;
}

- (bool)setCurrentProcessAsConfigurator {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    if (proxyAudioBox == kAudioObjectUnknown) {
        return true;
    }
    if (!AudioDevice::setIdentifyValue(proxyAudioBox, getpid())) {
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
        [delegate updateDriverStatus];
    });
    return noErr;
}

- (bool)setupListenerForCurrentAudioDevices {
    AudioObjectPropertyAddress listenerPropertyAddress = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    OSStatus err = AudioObjectAddPropertyListener(
        kAudioObjectSystemObject, &listenerPropertyAddress, &onDevicesChanged, (__bridge_retained void *)self);
    return err == noErr;
}

- (bool)proxyAudioDeviceAvailable {
    return AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID)) != kAudioObjectUnknown;
}

- (BOOL)driverBundleInstalled {
    return [[NSFileManager defaultManager] fileExistsAtPath:kHALDriverPath];
}

- (NSString *)bundledDriverPath {
    return [[NSBundle mainBundle] pathForResource:@"ProxyAudioDevice" ofType:@"driver"];
}

#pragma mark - Native UI

- (void)buildNativeUI {
    if (nativeUIBuilt || !self.window) {
        return;
    }

    NSWindow *window = self.window;
    window.title = @"Proxy Audio";
    window.contentMinSize = NSMakeSize(460, 420);
    [window setContentSize:NSMakeSize(500, 520)];

    NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
    window.contentView = content;

    NSStackView *root = [[NSStackView alloc] init];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 18;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:content.topAnchor constant:22],
        [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:22],
        [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-22],
        [root.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-22],
    ]];

    [root addArrangedSubview:[self makeDriverStatusRow]];
    [root addArrangedSubview:[self separator]];

    self.settingsContainer = [[NSStackView alloc] init];
    NSStackView *settings = (NSStackView *)self.settingsContainer;
    settings.orientation = NSUserInterfaceLayoutOrientationVertical;
    settings.alignment = NSLayoutAttributeLeading;
    settings.spacing = 18;
    settings.translatesAutoresizingMaskIntoConstraints = NO;
    [settings.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;
    [root addArrangedSubview:settings];

    [settings addArrangedSubview:[self makeSectionLabel:@"输出"]];
    [settings addArrangedSubview:[self makeOutputForm]];
    [settings addArrangedSubview:[self separator]];
    [settings addArrangedSubview:[self makeSectionLabel:@"保持工作"]];
    [settings addArrangedSubview:[self makeActiveConditionGroup]];

    nativeUIBuilt = true;
}

- (NSView *)separator {
    NSBox *line = [[NSBox alloc] init];
    line.boxType = NSBoxSeparator;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [line.heightAnchor constraintEqualToConstant:1].active = YES;
    [line.widthAnchor constraintGreaterThanOrEqualToConstant:400].active = YES;
    return line;
}

- (NSTextField *)makeSectionLabel:(NSString *)title {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

- (NSView *)makeDriverStatusRow {
    NSStackView *row = [NSStackView stackViewWithViews:@[]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    self.driverStatusImage = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.driverStatusImage.translatesAutoresizingMaskIntoConstraints = NO;
    [self.driverStatusImage.widthAnchor constraintEqualToConstant:18].active = YES;
    [self.driverStatusImage.heightAnchor constraintEqualToConstant:18].active = YES;

    self.driverStatusLabel = [NSTextField labelWithString:@"正在检查驱动…"];
    self.driverStatusLabel.font = [NSFont systemFontOfSize:13];

    NSView *spacer = [[NSView alloc] init];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.driverActionButton = [NSButton buttonWithTitle:@"安装驱动" target:self action:@selector(driverActionClicked:)];
    self.driverActionButton.bezelStyle = NSBezelStyleRounded;

    [row addArrangedSubview:self.driverStatusImage];
    [row addArrangedSubview:self.driverStatusLabel];
    [row addArrangedSubview:spacer];
    [row addArrangedSubview:self.driverActionButton];
    [row.widthAnchor constraintGreaterThanOrEqualToConstant:400].active = YES;
    return row;
}

- (NSView *)makeOutputForm {
    NSGridView *grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
    grid.rowSpacing = 10;
    grid.columnSpacing = 12;
    grid.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *nameLabel = [NSTextField labelWithString:@"名称"];
    nameLabel.alignment = NSTextAlignmentRight;
    self.deviceNameTextField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.deviceNameTextField.target = self;
    self.deviceNameTextField.action = @selector(deviceNameEntered:);
    [self.deviceNameTextField.widthAnchor constraintGreaterThanOrEqualToConstant:280].active = YES;

    NSTextField *targetLabel = [NSTextField labelWithString:@"电视"];
    targetLabel.alignment = NSTextAlignmentRight;
    self.outputDevicePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.outputDevicePopUp.target = self;
    self.outputDevicePopUp.action = @selector(outputDeviceSelected:);
    self.outputDevicePopUp.autoenablesItems = NO;

    NSTextField *bufferLabel = [NSTextField labelWithString:@"缓冲"];
    bufferLabel.alignment = NSTextAlignmentRight;
    self.bufferSizePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.bufferSizePopUp.target = self;
    self.bufferSizePopUp.action = @selector(outputDeviceBufferFrameSizeSelected:);
    for (NSString *size in @[ @"8", @"16", @"32", @"64", @"128", @"256", @"512", @"1024", @"2048" ]) {
        [self.bufferSizePopUp addItemWithTitle:size];
    }
    [self.bufferSizePopUp selectItemWithTitle:@"512"];

    [grid addRowWithViews:@[ nameLabel, self.deviceNameTextField ]];
    [grid addRowWithViews:@[ targetLabel, self.outputDevicePopUp ]];
    [grid addRowWithViews:@[ bufferLabel, self.bufferSizePopUp ]];
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementFill;
    return grid;
}

- (NSView *)makeActiveConditionGroup {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    self.proxiedDeviceIsActiveRadioButton = [self radio:@"有声音在播放时" action:@selector(proxiedDeviceIsActiveConditionSelected:)];
    self.userIsActiveRadioButton = [self radio:@"使用电脑时" action:@selector(userIsActiveConditionSelected:)];
    self.alwaysRadioButton = [self radio:@"始终（会阻止睡眠）" action:@selector(alwaysConditionSelected:)];

    [stack addArrangedSubview:[self radioBlock:self.proxiedDeviceIsActiveRadioButton
                                       caption:@"最省电，但声音刚响起时可能被切掉一小截"]];
    [stack addArrangedSubview:[self radioBlock:self.userIsActiveRadioButton
                                       caption:@"正在用电脑时保持输出，闲置后停止，不挡住睡眠"]];
    [stack addArrangedSubview:[self radioBlock:self.alwaysRadioButton
                                       caption:@"声音最稳，但电脑可能无法休眠"]];
    return stack;
}

- (NSButton *)radio:(NSString *)title action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    [button setButtonType:NSButtonTypeRadio];
    button.title = title;
    button.target = self;
    button.action = action;
    button.font = [NSFont systemFontOfSize:13];
    return button;
}

- (NSView *)radioBlock:(NSButton *)button caption:(NSString *)caption {
    NSStackView *block = [[NSStackView alloc] init];
    block.orientation = NSUserInterfaceLayoutOrientationVertical;
    block.alignment = NSLayoutAttributeLeading;
    block.spacing = 2;
    NSTextField *hint = [NSTextField wrappingLabelWithString:caption];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.preferredMaxLayoutWidth = 420;
    [block addArrangedSubview:button];
    [block addArrangedSubview:hint];
    return block;
}

- (void)setSettingsEnabled:(BOOL)enabled {
    self.settingsContainer.hidden = !enabled;
    self.deviceNameTextField.enabled = enabled;
    self.outputDevicePopUp.enabled = enabled;
    self.bufferSizePopUp.enabled = enabled;
    self.proxiedDeviceIsActiveRadioButton.enabled = enabled;
    self.userIsActiveRadioButton.enabled = enabled;
    self.alwaysRadioButton.enabled = enabled;
}

- (void)updateDriverStatus {
    BOOL loaded = [self proxyAudioDeviceAvailable];
    BOOL installed = [self driverBundleInstalled];

    NSString *symbol = @"xmark.circle.fill";
    NSColor *tint = [NSColor systemRedColor];
    NSString *status = @"未安装驱动";
    NSString *action = @"安装驱动";
    BOOL actionEnabled = YES;

    if (loaded) {
        symbol = @"checkmark.circle.fill";
        tint = [NSColor systemGreenColor];
        status = @"驱动已就绪";
        action = @"卸载驱动";
    } else if (installed) {
        symbol = @"exclamationmark.circle.fill";
        tint = [NSColor systemOrangeColor];
        status = @"驱动已安装，正在加载…";
        action = @"卸载驱动";
    }

    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:status];
        self.driverStatusImage.image = image;
        self.driverStatusImage.contentTintColor = tint;
    }
    self.driverStatusLabel.stringValue = status;
    self.driverActionButton.title = action;
    self.driverActionButton.enabled = actionEnabled;
    if (![self bundledDriverPath] && !loaded && !installed) {
        self.driverActionButton.enabled = NO;
        self.driverStatusLabel.stringValue = @"未找到内置驱动，请重新构建应用";
    }
}

- (void)updateActiveConditionControls {
    ProxyAudioDevice::ActiveCondition condition = [self currentOutputDeviceActiveCondition];
    self.proxiedDeviceIsActiveRadioButton.state =
        condition == ProxyAudioDevice::ActiveCondition::proxiedDeviceActive ? NSControlStateValueOn : NSControlStateValueOff;
    self.userIsActiveRadioButton.state =
        condition == ProxyAudioDevice::ActiveCondition::userActive ? NSControlStateValueOn : NSControlStateValueOff;
    self.alwaysRadioButton.state =
        condition == ProxyAudioDevice::ActiveCondition::always ? NSControlStateValueOn : NSControlStateValueOff;
}

#pragma mark - Driver install / uninstall

- (IBAction)driverActionClicked:(id)sender {
#pragma unused(sender)
    if ([self proxyAudioDeviceAvailable] || [self driverBundleInstalled]) {
        [self uninstallDriver];
    } else {
        [self installDriver];
    }
}

- (BOOL)runPrivilegedAppleScript:(NSString *)source errorMessage:(NSString **)message {
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *errorInfo = nil;
    NSAppleEventDescriptor *result = [script executeAndReturnError:&errorInfo];
    if (!result) {
        NSNumber *number = errorInfo[NSAppleScriptErrorNumber];
        if (number.intValue == -128) {
            if (message) {
                *message = @"已取消";
            }
            return NO;
        }
        if (message) {
            *message = errorInfo[NSAppleScriptErrorMessage] ?: @"未知错误";
        }
        return NO;
    }
    return YES;
}

- (void)installDriver {
    NSString *src = [self bundledDriverPath];
    if (src.length == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"找不到内置驱动";
        alert.informativeText = @"请重新构建这个应用后再试。";
        [alert runModal];
        return;
    }

    NSString *source = [NSString stringWithFormat:
        @"set src to quoted form of \"%@\"\n"
         "set dst to quoted form of \"%@\"\n"
         "do shell script \"rm -rf \" & dst & \" && cp -R \" & src & \" \" & dst & \" && chown -R root:wheel \" & dst & \" && killall coreaudiod\" with administrator privileges",
        src,
        kHALDriverPath];

    NSString *errorMessage = nil;
    if (![self runPrivilegedAppleScript:source errorMessage:&errorMessage]) {
        if (![errorMessage isEqualToString:@"已取消"]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"安装失败";
            alert.informativeText = errorMessage;
            [alert runModal];
        }
        return;
    }

    initializationAttemptInterval = 3;
    [self updateDriverStatus];
    [self keepTryingToInitializeUntilSuccess];
}

- (void)uninstallDriver {
    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = @"卸载驱动？";
    confirm.informativeText = @"系统将不再显示 Proxy Audio Device。需要管理员密码。";
    [confirm addButtonWithTitle:@"卸载"];
    [confirm addButtonWithTitle:@"取消"];
    if ([confirm runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    NSString *source = [NSString stringWithFormat:
        @"set dst to quoted form of \"%@\"\n"
         "do shell script \"rm -rf \" & dst & \" && killall coreaudiod\" with administrator privileges",
        kHALDriverPath];

    NSString *errorMessage = nil;
    if (![self runPrivilegedAppleScript:source errorMessage:&errorMessage]) {
        if (![errorMessage isEqualToString:@"已取消"]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"卸载失败";
            alert.informativeText = errorMessage;
            [alert runModal];
        }
        return;
    }

    [self setSettingsEnabled:NO];
    lastDeviceListSignature = nil;
    [self updateDriverStatus];
}

#pragma mark - Configuration

- (NSString *)currentDeviceName {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)ProxyAudioDevice::ConfigType::deviceName));
    NSString *result = (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
    return result ? result : @"Proxy Audio Device";
}

- (IBAction)deviceNameEntered:(id)sender {
#pragma unused(sender)
    NSString *newName = [self.deviceNameTextField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (newName.length == 0) {
        self.deviceNameTextField.stringValue = [self currentDeviceName];
        return;
    }
    [self writeConfigString:[NSString stringWithFormat:@"deviceName=%@", newName]];
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
    if (self.window.isVisible) {
        [self updateDriverStatus];
        if ([self proxyAudioDeviceAvailable]) {
            [self refreshOutputDevices];
        }
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
    if (![self proxyAudioDeviceAvailable]) {
        return true;
    }

    NSString *signature = [self currentDeviceListSignature];
    if ([signature isEqualToString:lastDeviceListSignature] && self.outputDevicePopUp.numberOfItems > 0) {
        return true;
    }
    lastDeviceListSignature = signature;

    [self.outputDevicePopUp removeAllItems];
    std::vector<AudioDeviceID> devices = AudioDevice::devicesWithOutputCapabilitiesThatAreNotProxyAudioDevice();
    currentDeviceList.clear();
    NSString *storedUID = [self currentOutputDeviceUID];
    bool foundStoredDevice = false;
    bool success = false;

    for (AudioDeviceID device : devices) {
        NSString *deviceName = (__bridge_transfer NSString *)AudioDevice::copyObjectName(device);
        NSString *uid = (__bridge_transfer NSString *)AudioDevice::copyDeviceUID(device);
        if (!deviceName) {
            continue;
        }
        if (uid.length > 0) {
            [self cacheName:deviceName forUID:uid];
        }
        [self.outputDevicePopUp addItemWithTitle:deviceName];
        currentDeviceList.push_back(device);
        if (storedUID.length > 0 && [uid isEqualToString:storedUID]) {
            [self.outputDevicePopUp selectItemAtIndex:(NSInteger)currentDeviceList.size() - 1];
            foundStoredDevice = true;
        }
        success = true;
    }

    if (!foundStoredDevice && storedUID.length > 0) {
        NSString *displayName = [self currentOutputDeviceDisplayName] ?: storedUID;
        NSString *offlineName = [NSString stringWithFormat:@"%@（离线）", displayName];
        [self.outputDevicePopUp addItemWithTitle:offlineName];
        currentDeviceList.push_back(kAudioObjectUnknown);
        [self.outputDevicePopUp selectItemAtIndex:(NSInteger)currentDeviceList.size() - 1];
        success = true;
    }

    return success;
}

- (IBAction)outputDeviceSelected:(id)sender {
#pragma unused(sender)
    NSInteger index = self.outputDevicePopUp.indexOfSelectedItem;
    if (index < 0 || (unsigned long)index >= currentDeviceList.size()) {
        return;
    }
    if (currentDeviceList[(unsigned long)index] == kAudioObjectUnknown) {
        return;
    }
    NSString *uid = (__bridge_transfer NSString *)AudioDevice::copyDeviceUID(currentDeviceList[(unsigned long)index]);
    if (!uid) {
        return;
    }
    [self writeConfigString:[NSString stringWithFormat:@"outputDevice=%@", uid]];
    lastDeviceListSignature = nil;
    [self refreshOutputDevices];
}

- (NSString *)currentOutputDeviceBufferFrameSize {
    return [self readConfigValueForType:ProxyAudioDevice::ConfigType::outputDeviceBufferFrameSize] ?: @"";
}

- (IBAction)outputDeviceBufferFrameSizeSelected:(id)sender {
#pragma unused(sender)
    NSString *size = self.bufferSizePopUp.titleOfSelectedItem;
    if (!size) {
        return;
    }
    [self writeConfigString:[NSString stringWithFormat:@"outputDeviceBufferFrameSize=%@", size]];
}

- (ProxyAudioDevice::ActiveCondition)currentOutputDeviceActiveCondition {
    NSString *result = [self readConfigValueForType:ProxyAudioDevice::ConfigType::deviceActiveCondition];
    return (ProxyAudioDevice::ActiveCondition)[result intValue];
}

- (void)setCurrentOutputDeviceActiveCondition:(ProxyAudioDevice::ActiveCondition)condition {
    [self writeConfigString:[NSString stringWithFormat:@"outputDeviceActiveCondition=%d", (int)condition]];
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

@end
