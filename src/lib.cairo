pub mod addresses;
pub mod constants;
pub mod shared {
    pub mod components {
        pub mod reentrancy_guard;
        pub mod src5;
    }
}
pub mod interfaces {
    pub mod erc20;
}
pub mod lever {
    pub mod constants;
    pub mod contracts {
        pub mod lever;
    }
    pub mod interfaces {
        pub mod lever;
    }
    pub mod types;

    #[cfg(test)]
    pub mod tests {
        pub mod malicious_lever;
        pub mod test_lever;
    }
}
pub mod stabilizer {
    pub mod constants;
    pub mod contracts {
        pub mod stabilizer;
    }
    pub mod interfaces {
        pub mod stabilizer;
    }
    pub mod math;
    pub mod periphery {
        pub mod estimator;
        pub mod frontend_data_provider;
    }
    pub mod types;

    #[cfg(test)]
    pub mod tests {
        mod test_estimator;
        mod test_stabilizer;
        pub mod utils;
    }
}

pub mod archabbot {
    pub mod contracts {
        pub mod archabbot;
        pub mod restricted_archabbot;
        pub mod rites {
            pub mod interfaces;
            pub mod types;
            pub mod utils;
            pub mod topup {
                pub mod constants;
                pub mod topup_rite;
                pub mod types;
            }
            pub mod dca {
                pub mod ekubo_dca_component;
                pub mod ekubo_oracle_component;
                pub mod price_dca_rite;
                pub mod time_dca_rite;
                pub mod types;
                pub mod utils;
            }
        }
    }
    pub mod interfaces {
        pub mod celebrant;
        pub mod lever;
        pub mod rite;
    }
    pub mod types;
    pub mod utils {
        pub mod sqrt_ratio_limit;
    }

    #[cfg(test)]
    pub mod tests {
        pub mod test_archabbot;
        pub mod test_archabbot_lever;
        pub mod test_types;
        pub mod utils;
        pub mod mocks {
            pub mod fake_src5_rite;
            pub mod malicious_lever;
            pub mod mock_rite;
            pub mod no_callback_rite;
            pub mod reentrant_rite;
            pub mod trove_opening_rite;
        }
        pub mod rites {
            pub mod test_topup_rite;
        }
    }
}
