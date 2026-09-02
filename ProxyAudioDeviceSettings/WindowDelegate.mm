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
    NSView *advancedContainer;
    NSTextField *activityCaptionLabel;
    NSButton *advancedToggle;
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
    window.styleMask |= NSWindowStyleMaskResizable;
    window.contentMinSize = NSMakeSize(380, 320);
    window.contentMaxSize = NSMakeSize(720, 900);

    NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
    window.contentView = content;

    NSStackView *root = [[NSStackView alloc] init];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 14;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
        [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
        [root.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18],
    ]];

    NSView *statusCard = [self cardWithTitle:nil content:[self makeDriverStatusRow]];
    NSView *outputCard = [self cardWithTitle:@"输出" content:[self makeOutputForm]];
    NSView *activeCard = [self cardWithTitle:@"保持工作" content:[self makeActiveConditionGroup]];
    NSView *advancedCard = [self cardWithTitle:nil content:[self makeAdvancedForm]];
    advancedContainer = advancedCard;
    advancedContainer.hidden = YES;

    [root addArrangedSubview:statusCard];

    self.settingsContainer = [[NSStackView alloc] init];
    NSStackView *settings = (NSStackView *)self.settingsContainer;
    settings.orientation = NSUserInterfaceLayoutOrientationVertical;
    settings.alignment = NSLayoutAttributeLeading;
    settings.spacing = 14;
    settings.translatesAutoresizingMaskIntoConstraints = NO;
    [root addArrangedSubview:settings];

    [settings addArrangedSubview:outputCard];
    [settings addArrangedSubview:activeCard];
    [settings addArrangedSubview:[self makeAdvancedToggle]];
    [settings addArrangedSubview:advancedCard];

    [NSLayoutConstraint activateConstraints:@[
        [statusCard.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [settings.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [outputCard.widthAnchor constraintEqualToAnchor:settings.widthAnchor],
        [activeCard.widthAnchor constraintEqualToAnchor:settings.widthAnchor],
        [advancedCard.widthAnchor constraintEqualToAnchor:settings.widthAnchor],
    ]];

    [self sizeWindowToFit];
    nativeUIBuilt = true;
}

- (void)sizeWindowToFit {
    [self.window.contentView layoutSubtreeIfNeeded];
    NSSize fitting = self.window.contentView.fittingSize;
    fitting.width = MAX(fitting.width, 420);
    fitting.height = MAX(fitting.height, 300);
    [self.window setContentSize:fitting];
}

- (NSView *)cardWithTitle:(NSString *)title content:(NSView *)content {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    if (title.length > 0) {
        [stack addArrangedSubview:[self makeSectionLabel:title]];
    }

    NSBox *box = [[NSBox alloc] init];
    box.boxType = NSBoxCustom;
    box.borderWidth = 0;
    box.cornerRadius = 10;
    box.fillColor = [NSColor controlBackgroundColor];
    box.titlePosition = NSNoTitle;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.contentViewMargins = NSMakeSize(14, 12);
    [box.contentView addSubview:content];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:box.contentView.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor],
    ]];

    [stack addArrangedSubview:box];
    [box.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    return stack;
}

- (NSTextField *)makeSectionLabel:(NSString *)title {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    label.textColor = [NSColor secondaryLabelColor];
    label.alignment = NSTextAlignmentNatural;
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
    [self.driverStatusImage.widthAnchor constraintEqualToConstant:16].active = YES;
    [self.driverStatusImage.heightAnchor constraintEqualToConstant:16].active = YES;

    self.driverStatusLabel = [NSTextField labelWithString:@"正在检查驱动…"];
    self.driverStatusLabel.font = [NSFont systemFontOfSize:13];

    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.driverActionButton = [NSButton buttonWithTitle:@"安装" target:self action:@selector(driverActionClicked:)];
    self.driverActionButton.bezelStyle = NSBezelStyleFlexiblePush;
    self.driverActionButton.controlSize = NSControlSizeSmall;

    [row addArrangedSubview:self.driverStatusImage];
    [row addArrangedSubview:self.driverStatusLabel];
    [row addArrangedSubview:spacer];
    [row addArrangedSubview:self.driverActionButton];
    return row;
}

- (NSView *)formRowWithTitle:(NSString *)title field:(NSView *)field {
    NSTextField *label = [NSTextField labelWithString:title];
    label.alignment = NSTextAlignmentRight;
    label.font = [NSFont systemFontOfSize:13];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label.widthAnchor constraintEqualToConstant:36].active = YES;
    [label setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *row = [NSStackView stackViewWithViews:@[ label, field ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 10;
    [field setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [field setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return row;
}

- (NSView *)makeOutputForm {
    self.outputDevicePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.outputDevicePopUp.target = self;
    self.outputDevicePopUp.action = @selector(outputDeviceSelected:);
    self.outputDevicePopUp.autoenablesItems = NO;

    NSButton *soundButton = [NSButton buttonWithTitle:@"系统声音设置" target:self action:@selector(openSoundSettings:)];
    soundButton.bezelStyle = NSBezelStyleFlexiblePush;
    soundButton.controlSize = NSControlSizeSmall;

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [stack addArrangedSubview:[self formRowWithTitle:@"电视" field:self.outputDevicePopUp]];
    [stack addArrangedSubview:soundButton];
    return stack;
}

- (NSView *)makeAdvancedForm {
    self.deviceNameTextField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.deviceNameTextField.target = self;
    self.deviceNameTextField.action = @selector(deviceNameEntered:);

    self.bufferSizePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.bufferSizePopUp.target = self;
    self.bufferSizePopUp.action = @selector(outputDeviceBufferFrameSizeSelected:);
    for (NSString *size in @[ @"8", @"16", @"32", @"64", @"128", @"256", @"512", @"1024", @"2048" ]) {
        [self.bufferSizePopUp addItemWithTitle:size];
    }
    [self.bufferSizePopUp selectItemWithTitle:@"512"];

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [stack addArrangedSubview:[self formRowWithTitle:@"名称" field:self.deviceNameTextField]];
    [stack addArrangedSubview:[self formRowWithTitle:@"缓冲" field:self.bufferSizePopUp]];
    return stack;
}

- (NSView *)makeAdvancedToggle {
    advancedToggle = [NSButton buttonWithTitle:@"高级" target:self action:@selector(toggleAdvanced:)];
    advancedToggle.bezelStyle = NSBezelStyleFlexiblePush;
    advancedToggle.controlSize = NSControlSizeSmall;
    return advancedToggle;
}

- (void)toggleAdvanced:(id)sender {
#pragma unused(sender)
    advancedContainer.hidden = !advancedContainer.hidden;
    advancedToggle.title = advancedContainer.hidden ? @"高级" : @"隐藏高级";
    [self sizeWindowToFit];
}

- (NSView *)makeActiveConditionGroup {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    self.proxiedDeviceIsActiveRadioButton = [self radio:@"仅播放时" action:@selector(proxiedDeviceIsActiveConditionSelected:)];
    self.userIsActiveRadioButton = [self radio:@"使用电脑时" action:@selector(userIsActiveConditionSelected:)];
    self.alwaysRadioButton = [self radio:@"始终" action:@selector(alwaysConditionSelected:)];

    activityCaptionLabel = [NSTextField wrappingLabelWithString:@""];
    activityCaptionLabel.font = [NSFont systemFontOfSize:11];
    activityCaptionLabel.textColor = [NSColor secondaryLabelColor];
    activityCaptionLabel.preferredMaxLayoutWidth = 340;

    [stack addArrangedSubview:self.proxiedDeviceIsActiveRadioButton];
    [stack addArrangedSubview:self.userIsActiveRadioButton];
    [stack addArrangedSubview:self.alwaysRadioButton];
    [stack addArrangedSubview:activityCaptionLabel];
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
    NSString *action = @"安装";
    BOOL actionEnabled = YES;

    if (loaded) {
        symbol = @"checkmark.circle.fill";
        tint = [NSColor systemGreenColor];
        status = @"驱动已就绪";
        action = @"卸载";
    } else if (installed) {
        symbol = @"exclamationmark.circle.fill";
        tint = [NSColor systemOrangeColor];
        status = @"驱动已安装，正在加载…";
        action = @"卸载";
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
    [self updateActivityCaption];
}

- (void)updateActivityCaption {
    NSString *caption = @"使用电脑时保持输出，闲置后停止，不阻止睡眠。";
    if (self.proxiedDeviceIsActiveRadioButton.state == NSControlStateValueOn) {
        caption = @"最省电，声音刚响起时可能被切掉一小截。";
    } else if (self.alwaysRadioButton.state == NSControlStateValueOn) {
        caption = @"声音最稳，但可能会阻止电脑休眠。";
    }
    activityCaptionLabel.stringValue = caption;
}

#pragma mark - Driver install / uninstall

- (IBAction)openSoundSettings:(id)sender {
#pragma unused(sender)
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Sound-Settings.extension"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

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
    [self updateActivityCaption];
}

- (IBAction)userIsActiveConditionSelected:(id)sender {
#pragma unused(sender)
    self.alwaysRadioButton.state = NSControlStateValueOff;
    self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::userActive];
    [self updateActivityCaption];
}

- (IBAction)alwaysConditionSelected:(id)sender {
#pragma unused(sender)
    self.proxiedDeviceIsActiveRadioButton.state = NSControlStateValueOff;
    self.userIsActiveRadioButton.state = NSControlStateValueOff;
    [self setCurrentOutputDeviceActiveCondition:ProxyAudioDevice::ActiveCondition::always];
    [self updateActivityCaption];
}

@end
