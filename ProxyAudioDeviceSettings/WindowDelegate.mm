#include <vector>
#include <CoreAudio/CoreAudio.h>
#import "WindowDelegate.h"
#include "AudioDevice.h"
#include "ProxyAudioDevice.h"

static NSString *const kDeviceNameCacheKey = @"deviceNameCacheByUID";
static NSString *const kHALDriverPath = @"/Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver";

@implementation WindowDelegate {
    std::vector<AudioDeviceID> currentDeviceList;
    NSTimer *refreshTimer;
    NSString *lastDeviceListSignature;
    bool nativeUIBuilt;
    NSView *advancedContainer;
    NSTextField *activityCaptionLabel;
    NSButton *advancedToggle;
    NSButton *enableOutputButton;
    NSButton *installButton;
    AudioDeviceID configuredBox;
    NSStackView *rootStack;
    NSTextField *bufferHint;

}

- (void)awakeFromNib {
    nativeUIBuilt = false;
    [self buildNativeUI];
    for (NSMenuItem *item in [NSApp.mainMenu.itemArray copy]) {
        if ([item.title isEqualToString:@"File"] || [item.title isEqualToString:@"Help"]) {
            [NSApp.mainMenu removeItem:item];
        }
    }
    [self updateDriverStatus];
    [self setSettingsEnabled:NO];
    [self startRefreshTimer];
    [self initialize];
}

- (bool)initialize {
    [self updateDriverStatus];

    if (![self proxyAudioDeviceAvailable]) {
        [self setSettingsEnabled:NO];
        configuredBox = kAudioObjectUnknown;
        return false;
    }

    if (![self setCurrentProcessAsConfigurator]) {
        return false;
    }

    lastDeviceListSignature = nil;
    self.deviceNameTextField.stringValue = [self currentDeviceName];

    if (![self refreshOutputDevices]) {
        return false;
    }


    [self startRefreshTimer];

    NSString *bufferSize = [self currentOutputDeviceBufferFrameSize];
    if (bufferSize.length > 0) {
        [self.bufferSizePopUp selectItemWithTitle:bufferSize];
    }

    configuredBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
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
    window.title = @"Display Volume";
    window.styleMask |= NSWindowStyleMaskResizable;
    window.contentMinSize = NSMakeSize(420, 200);
    window.contentMaxSize = NSMakeSize(560, 780);
    window.titlebarAppearsTransparent = YES;
    window.autorecalculatesKeyViewLoop = YES;
    [window setFrameAutosaveName:@"ProxyAudioSettings"];
    window.backgroundColor = [NSColor windowBackgroundColor];

    NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
    window.contentView = content;

    NSStackView *root = [[NSStackView alloc] init];
    rootStack = root;
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 14;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
        [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
        [root.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-18],
    ]];

    NSView *statusCard = [self cardWithTitle:nil content:[self makeDriverStatusRow]];
    NSView *outputCard = [self cardWithTitle:@"输出" content:[self makeOutputForm]];
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
    NSView *footer = [self makeAdvancedToggle];
    [settings addArrangedSubview:footer];
    [footer.widthAnchor constraintEqualToAnchor:settings.widthAnchor].active = YES;
    [settings addArrangedSubview:advancedCard];

    [NSLayoutConstraint activateConstraints:@[
        [statusCard.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [settings.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [outputCard.widthAnchor constraintEqualToAnchor:settings.widthAnchor],
        [advancedCard.widthAnchor constraintEqualToAnchor:settings.widthAnchor],
    ]];

    [self sizeWindowToFit];
    nativeUIBuilt = true;
}

- (void)sizeWindowToFit {
    [self.window.contentView layoutSubtreeIfNeeded];
    NSSize fitting = rootStack.fittingSize;
    fitting.width = MAX(self.window.contentView.frame.size.width, 420);
    fitting.height = MAX(fitting.height + 36, 200);
    self.window.contentMinSize = NSMakeSize(420, fitting.height);
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
    box.cornerRadius = 14;
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
    self.driverStatusLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];

    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.driverActionButton = [NSButton buttonWithTitle:@"安装" target:self action:@selector(driverActionClicked:)];
    self.driverActionButton.bezelStyle = NSBezelStyleFlexiblePush;
    self.driverActionButton.controlSize = NSControlSizeRegular;

    [row addArrangedSubview:self.driverStatusImage];
    [row addArrangedSubview:self.driverStatusLabel];
    [row addArrangedSubview:spacer];
    installButton = [NSButton buttonWithTitle:@"安装驱动" target:self action:@selector(driverActionClicked:)];
    installButton.bezelStyle = NSBezelStyleFlexiblePush;
    [row addArrangedSubview:installButton];
    return row;
}

- (NSView *)formRowWithTitle:(NSString *)title field:(NSView *)field {
    NSTextField *label = [NSTextField labelWithString:title];
    label.alignment = NSTextAlignmentRight;
    label.font = [NSFont systemFontOfSize:13];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label.widthAnchor constraintEqualToConstant:44].active = YES;
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

    enableOutputButton = [NSButton buttonWithTitle:@"设为系统输出" target:self action:@selector(enableSystemOutput:)];
    enableOutputButton.bezelStyle = NSBezelStyleFlexiblePush;

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    NSView *deviceRow = [self formRowWithTitle:@"设备" field:self.outputDevicePopUp];
    [stack addArrangedSubview:deviceRow];
    [deviceRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [stack addArrangedSubview:enableOutputButton];
    return stack;
}

- (NSView *)makeAdvancedForm {
    self.deviceNameTextField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.deviceNameTextField.target = self;
    self.deviceNameTextField.action = @selector(deviceNameEntered:);

    self.bufferSizePopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.bufferSizePopUp.target = self;
    self.bufferSizePopUp.action = @selector(outputDeviceBufferFrameSizeSelected:);
    self.bufferSizePopUp.autoenablesItems = NO;
    for (NSString *size in @[ @"128", @"256", @"512", @"1024", @"2048" ]) {
        [self.bufferSizePopUp addItemWithTitle:size];
    }
    [self.bufferSizePopUp selectItemWithTitle:@"512"];

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [stack addArrangedSubview:[self makeSectionLabel:@"运行方式"]];
    [stack addArrangedSubview:[self makeActiveConditionGroup]];
    for (NSView *row in @[[self formRowWithTitle:@"名称" field:self.deviceNameTextField],
                          [self formRowWithTitle:@"缓冲" field:self.bufferSizePopUp]]) {
        [stack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
    NSTextField *hint = [NSTextField wrappingLabelWithString:@"缓冲越大，播放越稳。默认 512。"];
    bufferHint = hint;
    hint.font = [NSFont systemFontOfSize:12];
    hint.textColor = [NSColor secondaryLabelColor];
    [stack addArrangedSubview:hint];
    NSButton *update = [NSButton buttonWithTitle:@"更新驱动…" target:self action:@selector(updateDriver:)];
    update.bezelStyle = NSBezelStyleFlexiblePush;
    NSStackView *driverActions = [NSStackView stackViewWithViews:@[update, self.driverActionButton]];
    driverActions.spacing = 10;
    [stack addArrangedSubview:driverActions];
    return stack;
}

- (NSView *)makeAdvancedToggle {
    advancedToggle = [NSButton buttonWithTitle:@"高级" target:self action:@selector(toggleAdvanced:)];
    advancedToggle.bezelStyle = NSBezelStyleFlexiblePush;
    advancedToggle.controlSize = NSControlSizeRegular;
    NSButton *soundButton = [NSButton buttonWithTitle:@"声音设置…" target:self action:@selector(openSoundSettings:)];
    soundButton.bordered = NO;
    soundButton.font = [NSFont systemFontOfSize:12];
    soundButton.contentTintColor = [NSColor secondaryLabelColor];
    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *footer = [NSStackView stackViewWithViews:@[advancedToggle, spacer, soundButton]];
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footer.alignment = NSLayoutAttributeCenterY;
    return footer;
}

- (void)toggleAdvanced:(id)sender {
#pragma unused(sender)
    advancedContainer.hidden = !advancedContainer.hidden;
    advancedToggle.title = advancedContainer.hidden ? @"高级" : @"收起高级";
    [self sizeWindowToFit];
}

- (NSView *)makeActiveConditionGroup {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    self.proxiedDeviceIsActiveRadioButton = [self radio:@"播放时" action:@selector(proxiedDeviceIsActiveConditionSelected:)];
    self.userIsActiveRadioButton = [self radio:@"自动（推荐）" action:@selector(userIsActiveConditionSelected:)];
    self.alwaysRadioButton = [self radio:@"持续运行" action:@selector(alwaysConditionSelected:)];

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
    BOOL changed = self.settingsContainer.hidden == enabled;
    self.settingsContainer.hidden = !enabled;
    self.deviceNameTextField.enabled = enabled;
    self.outputDevicePopUp.enabled = enabled;
    self.bufferSizePopUp.enabled = enabled;
    self.proxiedDeviceIsActiveRadioButton.enabled = enabled;
    self.userIsActiveRadioButton.enabled = enabled;
    self.alwaysRadioButton.enabled = enabled;
    if (changed) [self sizeWindowToFit];
}

- (void)updateDriverStatus {
    BOOL loaded = [self proxyAudioDeviceAvailable];
    BOOL installed = [self driverBundleInstalled];

    NSString *symbol = @"xmark.circle.fill";
    NSColor *tint = [NSColor systemRedColor];
    NSString *status = @"安装后即可用音量键调节";
    NSString *action = @"安装";
    BOOL actionEnabled = YES;

    if (loaded) {
        symbol = @"checkmark.circle.fill";
        tint = [NSColor systemGreenColor];
        NSString *targetUID = [self currentOutputDeviceUID];
        AudioDeviceID target = targetUID.length ? AudioDevice::audioDeviceIDForDeviceUID((__bridge CFStringRef)targetUID) : kAudioObjectUnknown;
        AudioDeviceID proxy = AudioDevice::audioDeviceIDForDeviceUID(CFSTR(kDevice_UID));
        BOOL enabled = proxy != kAudioObjectUnknown && AudioDevice::defaultOutputDevice() == proxy;
        if (target == kAudioObjectUnknown) {
            status = @"等待设备连接";
            symbol = @"clock.fill";
            tint = [NSColor secondaryLabelColor];
        } else if (!enabled) {
            status = @"尚未启用";
            symbol = @"speaker.wave.2";
            tint = [NSColor secondaryLabelColor];
        } else if ([[self readConfigValueForType:ProxyAudioDevice::ConfigType::outputRuntimeState] isEqualToString:@"0"]) {
            status = @"正在连接输出…";
            symbol = @"clock.fill";
            tint = [NSColor secondaryLabelColor];
        } else {
            status = @"已启用 · 音量键可用";
        }
        enableOutputButton.hidden = enabled;
        action = @"卸载";
    } else if (installed) {
        symbol = @"exclamationmark.circle.fill";
        tint = [NSColor systemOrangeColor];
        status = @"正在连接驱动…";
        action = @"卸载";
    }

    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:status];
        self.driverStatusImage.image = image;
        self.driverStatusImage.contentTintColor = tint;
    }
    self.driverStatusLabel.stringValue = status;
    self.driverActionButton.title = [action isEqualToString:@"卸载"] ? @"卸载驱动…" : @"安装驱动";
    installButton.hidden = loaded;
    installButton.title = installed ? @"移除驱动…" : @"安装驱动";
    installButton.enabled = installed || [self bundledDriverPath] != nil;
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
    NSString *caption = @"使用或播放时运行，空闲时暂停。";
    if (self.proxiedDeviceIsActiveRadioButton.state == NSControlStateValueOn) {
        caption = @"按需启动，开头可能有短暂延迟。";
    } else if (self.alwaysRadioButton.state == NSControlStateValueOn) {
        caption = @"随时可播放，可能影响自动睡眠。";
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

- (void)updateDriver:(id)sender {
#pragma unused(sender)
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"更新驱动？";
    alert.informativeText = @"更新会短暂中断声音，需要管理员密码。";
    [alert addButtonWithTitle:@"更新"];
    [alert addButtonWithTitle:@"取消"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [self installDriver];
    }];
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

    NSString *escapedSource = [[src stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
        stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *source = [NSString stringWithFormat:
        @"set src to quoted form of \"%@\"\n"
         "set dst to quoted form of \"%@\"\n"
         "do shell script \"rm -rf \" & dst & \" && cp -R \" & src & \" \" & dst & \" && chown -R root:wheel \" & dst & \" && killall coreaudiod\" with administrator privileges",
        escapedSource,
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

    [self updateDriverStatus];
    [self initialize];
}

- (void)uninstallDriver {
    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = @"卸载驱动？";
    confirm.informativeText = @"移除虚拟音频输出，需要管理员密码。";
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
    return result ? result : @"Display Volume";
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
    if (![self setCurrentProcessAsConfigurator]) return nil;
    if (!AudioDevice::setIdentifyValue(proxyAudioBox, -((SInt32)type))) return nil;
    return (__bridge_transfer NSString *)AudioDevice::copyObjectName(proxyAudioBox);
}

- (BOOL)writeConfigString:(NSString *)keyValue {
    AudioDeviceID proxyAudioBox = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    if (![self setCurrentProcessAsConfigurator]) return NO;
    OSStatus error = AudioDevice::setObjectName(proxyAudioBox, (__bridge CFStringRef)keyValue);
    if (error != noErr) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"设置未保存";
        alert.informativeText = @"驱动暂时不可用，请稍后重试。";
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return NO;
    }
    return YES;
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
    if (!self.window.isVisible) return;
    AudioDeviceID box = AudioDevice::audioDeviceIDForBoxUID(CFSTR(kBox_UID));
    if (box == kAudioObjectUnknown || box != configuredBox || self.settingsContainer.hidden) {
        [self initialize];
    } else {
        // coreaudiod can restart and reuse an object ID: renew the configurator identity.
        [self setCurrentProcessAsConfigurator];
        [self refreshOutputDevices];
        [self updateDriverStatus];
        NSString *actual = [self readConfigValueForType:ProxyAudioDevice::ConfigType::outputActualBufferSize];
        bufferHint.stringValue = actual.intValue > 0
            ? [NSString stringWithFormat:@"当前缓冲 %@ 帧。默认 512。", actual]
            : @"缓冲越大，播放越稳。默认 512。";
    }
}

- (void)refreshBufferChoices {
    NSString *uid = [self currentOutputDeviceUID];
    AudioDeviceID device = uid.length ? AudioDevice::audioDeviceIDForDeviceUID((__bridge CFStringRef)uid) : kAudioObjectUnknown;
    AudioValueRange range = {128, 2048};
    UInt32 size = sizeof(range);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyBufferFrameSizeRange,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    if (device != kAudioObjectUnknown) {
        AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &range);
    }
    [self.bufferSizePopUp removeAllItems];
    NSString *selected = [self currentOutputDeviceBufferFrameSize];
    for (NSNumber *frames in @[@128, @256, @512, @1024, @2048]) {
        if (frames.doubleValue >= range.mMinimum && frames.doubleValue <= range.mMaximum) {
            [self.bufferSizePopUp addItemWithTitle:frames.stringValue];
        }
    }
    if (self.bufferSizePopUp.numberOfItems == 0 && range.mMinimum > 0) {
        [self.bufferSizePopUp addItemWithTitle:[NSString stringWithFormat:@"%.0f", range.mMinimum]];
    }
    if (selected.intValue > 0 && ![self.bufferSizePopUp itemWithTitle:selected]) {
        [self.bufferSizePopUp addItemWithTitle:selected];
        [self.bufferSizePopUp itemWithTitle:selected].enabled = NO;
    }
    [self.bufferSizePopUp selectItemWithTitle:selected];
}

- (void)enableSystemOutput:(id)sender {
#pragma unused(sender)
    AudioDeviceID proxy = AudioDevice::audioDeviceIDForDeviceUID(CFSTR(kDevice_UID));
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster};
    OSStatus error = AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, sizeof(proxy), &proxy);
    if (error != noErr) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"暂时无法启用";
        alert.informativeText = @"请在声音设置中选择本应用的虚拟输出。";
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }
    [self updateDriverStatus];
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
    [self refreshBufferChoices];

    [self.outputDevicePopUp removeAllItems];
    std::vector<AudioDeviceID> devices = AudioDevice::devicesWithOutputCapabilitiesThatAreNotProxyAudioDevice();
    currentDeviceList.clear();
    NSString *storedUID = [self currentOutputDeviceUID];
    bool foundStoredDevice = false;
    bool success = true;

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

    if (currentDeviceList.empty()) {
        [self.outputDevicePopUp addItemWithTitle:@"暂无输出设备"];
        self.outputDevicePopUp.enabled = NO;
    } else {
        self.outputDevicePopUp.enabled = YES;
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
    if (![self writeConfigString:[NSString stringWithFormat:@"outputDeviceBufferFrameSize=%@", size]]) {
        [self refreshBufferChoices];
    }
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
