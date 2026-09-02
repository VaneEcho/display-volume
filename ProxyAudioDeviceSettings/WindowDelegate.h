#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface WindowDelegate : NSObject
@property(nonatomic, strong) IBOutlet NSWindow *window;
@property(nonatomic, strong) NSTextField *deviceNameTextField;
@property(nonatomic, strong) NSPopUpButton *outputDevicePopUp;
@property(nonatomic, strong) NSPopUpButton *bufferSizePopUp;
@property(nonatomic, strong) NSButton *proxiedDeviceIsActiveRadioButton;
@property(nonatomic, strong) NSButton *userIsActiveRadioButton;
@property(nonatomic, strong) NSButton *alwaysRadioButton;
@property(nonatomic, strong) NSTextField *driverStatusLabel;
@property(nonatomic, strong) NSImageView *driverStatusImage;
@property(nonatomic, strong) NSButton *driverActionButton;
@property(nonatomic, strong) NSView *settingsContainer;

- (void)awakeFromNib;
- (IBAction)deviceNameEntered:(id)sender;
- (IBAction)outputDeviceSelected:(id)sender;
- (IBAction)outputDeviceBufferFrameSizeSelected:(id)sender;
- (IBAction)proxiedDeviceIsActiveConditionSelected:(id)sender;
- (IBAction)userIsActiveConditionSelected:(id)sender;
- (IBAction)alwaysConditionSelected:(id)sender;
- (IBAction)driverActionClicked:(id)sender;

@end

NS_ASSUME_NONNULL_END
