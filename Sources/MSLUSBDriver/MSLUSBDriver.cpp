// MSLUSBDriver.cpp
//
// See MSLUSBDriver.iig and Sources/MSLUSBDriver/README.md for the overall
// status. As of this pass, this file is verified to compile for real -
// see README.md's build log - which is new; earlier drafts used a plain
// `override` shape (`Start(IOService *provider) override`) that doesn't
// match how `iig` actually dispatches these methods at all. The real
// shape, confirmed by generating MSLUSBDriver.h with the real `iig` tool
// and reading its output: `iig` turns `Start`/`Stop` into RPC-dispatched
// methods that call into `Start_Impl`/`Stop_Impl` (via the
// `<ClassName>_<Method>_Args` macros for the parameter list) - a
// DriverKit-wide convention, not specific to this class. Calling the
// superclass's own implementation from inside an `_Impl` override needs
// the `SUPERDISPATCH` macro (`OSMetaClass.h`) rather than a plain
// `super::Start(...)` call, since DriverKit dispatch goes through IORPC,
// not a normal C++ vtable.
//
// What this still does NOT attempt, deliberately: actually bridging
// claimed I/O back to msl-usbd (Sources/msl-usbd) across the
// dext/userspace boundary - needs a dedicated IOUserClient this driver
// would vend, real design work for whoever picks this up next with actual
// hardware to iterate against.

#include <DriverKit/IOLib.h>
#include <DriverKit/OSCollections.h>
#include <USBDriverKit/IOUSBHostDevice.h>

#include "MSLUSBDriver.h"

struct MSLUSBDriver_IVars
{
    IOUSBHostDevice *usbDevice = nullptr;
};

bool MSLUSBDriver::init(void)
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(MSLUSBDriver_IVars, 1);
    return ivars != nullptr;
}

kern_return_t MSLUSBDriver::Start_Impl(IOService_Start_Args)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        return ret;
    }

    ivars->usbDevice = OSDynamicCast(IOUSBHostDevice, provider);
    if (ivars->usbDevice == nullptr) {
        return kIOReturnNoDevice;
    }

    // Open() is what actually detaches whatever else currently holds the
    // device open (Apple's own system driver, in the Phase 2 case this
    // exists for) - see the real header's doc comment: "Child
    // IOUSBHostInterfaces may open simultaneous sessions, but only one
    // other service may open a session."
    ret = ivars->usbDevice->Open(this, 0, 0);
    if (ret != kIOReturnSuccess) {
        return ret;
    }

    // TODO (needs real hardware + an approved/locally-trusted entitlement
    // to even attempt): vend an IOUserClient here so msl-usbd can attach
    // and drive ivars->usbDevice's DeviceRequest/descriptor methods from
    // userspace, the DriverKit-side mirror of what
    // Sources/MSLCore/USB/USBDeviceClaim already does for Phase 1's
    // unclaimed-device case.

    return kIOReturnSuccess;
}

kern_return_t MSLUSBDriver::Stop_Impl(IOService_Stop_Args)
{
    if (ivars != nullptr && ivars->usbDevice != nullptr) {
        ivars->usbDevice->Close(this, 0);
        ivars->usbDevice = nullptr;
    }
    return Stop(provider, SUPERDISPATCH);
}

void MSLUSBDriver::free(void)
{
    IOSafeDeleteNULL(ivars, MSLUSBDriver_IVars, 1);
    super::free();
}
