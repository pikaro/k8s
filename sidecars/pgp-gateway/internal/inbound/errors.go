package inbound

type ErrorKind string

const (
	ErrorPermanent ErrorKind = "permanent"
	ErrorTemporary ErrorKind = "temporary"
)

type DeliveryError struct {
	Kind   ErrorKind
	Reason string
	Err    error
}

func (e *DeliveryError) Error() string {
	if e.Err == nil {
		return e.Reason
	}
	return e.Err.Error()
}

func (e *DeliveryError) Unwrap() error {
	return e.Err
}

func Permanent(reason string, err error) error {
	return &DeliveryError{Kind: ErrorPermanent, Reason: reason, Err: err}
}

func Temporary(reason string, err error) error {
	return &DeliveryError{Kind: ErrorTemporary, Reason: reason, Err: err}
}
