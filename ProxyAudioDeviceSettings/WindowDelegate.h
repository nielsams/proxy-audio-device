#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface WindowDelegate : NSObject
@property(nonatomic, strong) IBOutlet NSTextField *deviceNameTextField;
@property(nonatomic, strong) IBOutlet NSComboBox *outputDeviceComboBox;
@property(nonatomic, strong) IBOutlet NSComboBox *bufferSizeComboBox;
@property(nonatomic, strong) IBOutlet NSButton *proxiedDeviceIsActiveRadioButton;
@property(nonatomic, strong) IBOutlet NSButton *userIsActiveRadioButton;
@property(nonatomic, strong) IBOutlet NSButton *alwaysRadioButton;
@property(nonatomic, strong) IBOutlet NSButton *hideWhenUnavailableCheckbox;
@property(nonatomic, strong) IBOutlet NSButton *switchOnConnectCheckbox;
@property(nonatomic, strong) IBOutlet NSButton *switchOnDisconnectCheckbox;
@property(nonatomic, strong) IBOutlet NSPopUpButton *fallbackDevicePopUp;

- (void)awakeFromNib;
- (IBAction)deviceNameEntered:(id)sender;
- (IBAction)outputDeviceSelected:(id)sender;
- (IBAction)outputDeviceBufferFrameSizeSelected:(id)sender;
- (IBAction)proxiedDeviceIsActiveConditionSelected:(id)sender;
- (IBAction)userIsActiveConditionSelected:(id)sender;
- (IBAction)alwaysConditionSelected:(id)sender;
- (IBAction)hideWhenUnavailableToggled:(id)sender;
- (IBAction)automaticSwitchingChanged:(id)sender;
- (IBAction)fallbackDeviceSelected:(id)sender;

@end

NS_ASSUME_NONNULL_END
