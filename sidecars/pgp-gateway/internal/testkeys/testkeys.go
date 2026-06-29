package testkeys

import pgp "github.com/ProtonMail/gopenpgp/v3/crypto"

type KeyPair struct {
	PublicArmored  string
	PrivateArmored string
	Fingerprint    string
}

func Generate(name, email string) (KeyPair, error) {
	key, err := pgp.PGP().KeyGeneration().
		AddUserId(name, email).
		New().
		GenerateKey()
	if err != nil {
		return KeyPair{}, err
	}
	defer key.ClearPrivateParams()

	publicArmored, err := key.GetArmoredPublicKey()
	if err != nil {
		return KeyPair{}, err
	}
	privateArmored, err := key.Armor()
	if err != nil {
		return KeyPair{}, err
	}
	return KeyPair{
		PublicArmored:  publicArmored,
		PrivateArmored: privateArmored,
		Fingerprint:    key.GetFingerprint(),
	}, nil
}
